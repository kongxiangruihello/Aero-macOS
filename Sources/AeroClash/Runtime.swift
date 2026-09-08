import Foundation
import AppKit
import Darwin

enum CoreState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "内核已停止"
        case .starting: return "内核启动中"
        case .running: return "内核运行中"
        case .failed: return "内核异常"
        }
    }
}

enum AeroRuntimeError: LocalizedError {
    case missingCore
    case missingProfile
    case invalidResponse
    case commandFailed(String)
    case invalidSubscription

    var errorDescription: String? {
        switch self {
        case .missingCore: return "应用包中缺少 Mihomo 内核"
        case .missingProfile: return "找不到选中的配置文件"
        case .invalidResponse: return "Mihomo 返回了无法识别的数据"
        case .commandFailed(let message): return message
        case .invalidSubscription: return "订阅地址必须使用 HTTP 或 HTTPS"
        }
    }
}

final class MihomoProcess: @unchecked Sendable {
    private(set) var process: Process?
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    func start(configURL: URL, dataDirectory: URL, secret: String, controllerPort: Int, pidFileURL: URL, onOutput: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        stop()
        Self.cleanupStaleProcess(pidFileURL: pidFileURL)
        guard let executable = Bundle.main.url(forResource: "mihomo", withExtension: nil) else {
            throw AeroRuntimeError.missingCore
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-d", dataDirectory.path,
            "-f", configURL.path,
            "-ext-ctl", "127.0.0.1:\(controllerPort)",
            "-secret", secret
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = dataDirectory

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            output.split(whereSeparator: \.isNewline).forEach { onOutput(String($0)) }
        }
        process.terminationHandler = { task in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(task.terminationStatus)
        }

        try process.run()
        lock.lock(); self.process = process; lock.unlock()
        try String(process.processIdentifier).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    func stop() {
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        guard let current, current.isRunning else { return }
        current.terminate()
        let deadline = Date().addingTimeInterval(2)
        while current.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if current.isRunning { kill(current.processIdentifier, SIGKILL) }
    }

    static func cleanupStaleProcess(pidFileURL: URL) {
        defer { try? FileManager.default.removeItem(at: pidFileURL) }
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              kill(pid, 0) == 0 else { return }
        let check = Process()
        let pipe = Pipe()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "command="]
        check.standardOutput = pipe
        check.standardError = pipe
        try? check.run()
        check.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let command = String(data: data, encoding: .utf8) ?? ""
        guard command.contains("/Aero.app/Contents/Resources/mihomo"), command.contains("Application Support/Aero") else { return }
        kill(pid, SIGTERM)
        usleep(180_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

struct MihomoAPI: Sendable {
    let secret: String
    private let baseURL: URL

    init(secret: String, port: Int) {
        self.secret = secret
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AeroRuntimeError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let detail = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AeroRuntimeError.commandFailed("Mihomo API 请求失败：\(detail)")
        }
        return data
    }

    func waitUntilReady() async throws {
        var lastError: Error?
        for _ in 0..<50 {
            do {
                _ = try await request("/version")
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError ?? AeroRuntimeError.commandFailed("Mihomo 控制器启动超时")
    }
}

enum LocalPort {
    static func firstAvailable(startingAt start: Int = 17890, attempts: Int = 100) -> Int {
        for port in start..<(start + attempts) where isAvailable(port) { return port }
        return 17890
    }

    static func isAvailable(_ port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

struct ProfileRepository: Sendable {
    let root: URL
    let profilesDirectory: URL
    let providersDirectory: URL
    let metadataURL: URL
    let secretURL: URL
    let defaultProfileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("Aero", isDirectory: true)
        profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
        providersDirectory = root.appendingPathComponent("Providers", isDirectory: true)
        metadataURL = root.appendingPathComponent("profiles.json")
        secretURL = root.appendingPathComponent("controller.secret")
        defaultProfileURL = profilesDirectory.appendingPathComponent("default.yaml")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providersDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: defaultProfileURL.path) {
            try Self.defaultConfig.write(to: defaultProfileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultProfileURL.path)
        }
    }

    func loadProfiles() -> [Profile] {
        guard let data = try? Data(contentsOf: metadataURL),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data),
              !profiles.isEmpty else {
            return [Self.defaultProfile]
        }
        return profiles
    }

    func saveProfiles(_ profiles: [Profile]) throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    func loadOrCreateSecret() throws -> String {
        if let value = try? String(contentsOf: secretURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let value = "aero-\(UUID().uuidString.lowercased())"
        try value.write(to: secretURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        return value
    }

    func fileURL(for profile: Profile) -> URL {
        profilesDirectory.appendingPathComponent(profile.fileName)
    }

    func validate(configURL: URL, coreURL: URL) throws {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = coreURL
        task.arguments = ["-t", "-d", root.path, "-f", configURL.path, "-ext-ctl", "127.0.0.1:0"]
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "配置校验失败"
            throw AeroRuntimeError.commandFailed(detail)
        }
    }

    static let defaultProfile = Profile(
        id: "default",
        name: "默认直连配置",
        source: "内置安全配置",
        updated: "随应用提供",
        size: "1 KB",
        fileName: "default.yaml",
        remoteURL: nil,
        format: "builtin",
        payloadFileName: nil
    )

    static let defaultConfig = """
    mixed-port: 0
    allow-lan: false
    bind-address: 127.0.0.1
    mode: rule
    log-level: info
    ipv6: false
    proxies: []
    proxy-groups:
      - name: 节点选择
        type: select
        proxies:
          - DIRECT
    rules:
      - MATCH,DIRECT
    """
}

struct ProxySnapshot: Codable {
    struct Entry: Codable {
        let service: String
        let web: ProxyValue
        let secureWeb: ProxyValue
        let socks: ProxyValue
        let autoURL: AutoProxyValue
        let autoDiscovery: Bool
        let bypassDomains: [String]
    }

    struct ProxyValue: Codable {
        let enabled: Bool
        let server: String
        let port: Int
    }

    struct AutoProxyValue: Codable {
        let enabled: Bool
        let url: String
    }

    let entries: [Entry]
    let createdAt: Date
}

final class SystemProxyManager: @unchecked Sendable {
    private let snapshotURL: URL
    private let command = "/usr/sbin/networksetup"

    init(appSupportDirectory: URL) {
        snapshotURL = appSupportDirectory.appendingPathComponent("system-proxy-backup.json")
    }

    var hasActiveSnapshot: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    func enable(httpPort: Int, socksPort: Int) throws {
        if !hasActiveSnapshot {
            let snapshot = try captureSnapshot()
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        }
        let snapshot = try loadSnapshot()
        var commands: [String] = []
        for entry in snapshot.entries {
            let service = shellQuote(entry.service)
            commands += [
                "\(command) -setwebproxy \(service) 127.0.0.1 \(httpPort) off",
                "\(command) -setsecurewebproxy \(service) 127.0.0.1 \(httpPort) off",
                "\(command) -setsocksfirewallproxy \(service) 127.0.0.1 \(socksPort) off",
                "\(command) -setwebproxystate \(service) on",
                "\(command) -setsecurewebproxystate \(service) on",
                "\(command) -setsocksfirewallproxystate \(service) on",
                "\(command) -setautoproxystate \(service) off"
            ]
            let bypass = Array(Set(entry.bypassDomains + ["localhost", "127.0.0.1", "::1", "*.local"]))
            commands.append("\(command) -setproxybypassdomains \(service) \(bypass.map(shellQuote).joined(separator: " "))")
        }
        do {
            try runPrivilegedBatch(commands)
        } catch {
            if (try? runPrivilegedBatch(restoreCommands(for: snapshot))) != nil {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            throw error
        }
    }

    func disable() throws {
        guard hasActiveSnapshot else { return }
        let snapshot = try loadSnapshot()
        try runPrivilegedBatch(restoreCommands(for: snapshot))
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private func restoreCommands(for snapshot: ProxySnapshot) -> [String] {
        var commands: [String] = []
        for entry in snapshot.entries {
            let service = shellQuote(entry.service)
            commands += restoreCommands(for: entry.web, kind: "webproxy", service: service)
            commands += restoreCommands(for: entry.secureWeb, kind: "securewebproxy", service: service)
            commands += restoreCommands(for: entry.socks, kind: "socksfirewallproxy", service: service)
            if !entry.autoURL.url.isEmpty {
                commands.append("\(command) -setautoproxyurl \(service) \(shellQuote(entry.autoURL.url))")
            }
            commands.append("\(command) -setautoproxystate \(service) \(entry.autoURL.enabled ? "on" : "off")")
            commands.append("\(command) -setproxyautodiscovery \(service) \(entry.autoDiscovery ? "on" : "off")")
            let bypass = entry.bypassDomains.isEmpty ? "Empty" : entry.bypassDomains.map(shellQuote).joined(separator: " ")
            commands.append("\(command) -setproxybypassdomains \(service) \(bypass)")
        }
        return commands
    }

    private func captureSnapshot() throws -> ProxySnapshot {
        let output = try run(["-listallnetworkservices"])
        let services = output.split(whereSeparator: \.isNewline).dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
        guard !services.isEmpty else { throw AeroRuntimeError.commandFailed("未找到可用的 macOS 网络服务") }
        let entries = try services.map { service in
            ProxySnapshot.Entry(
                service: service,
                web: parseProxy(try run(["-getwebproxy", service])),
                secureWeb: parseProxy(try run(["-getsecurewebproxy", service])),
                socks: parseProxy(try run(["-getsocksfirewallproxy", service])),
                autoURL: parseAutoProxy(try run(["-getautoproxyurl", service])),
                autoDiscovery: parseEnabled(try run(["-getproxyautodiscovery", service])),
                bypassDomains: parseBypass(try run(["-getproxybypassdomains", service]))
            )
        }
        return ProxySnapshot(entries: entries, createdAt: Date())
    }

    private func loadSnapshot() throws -> ProxySnapshot {
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder().decode(ProxySnapshot.self, from: data)
    }

    private func restoreCommands(for value: ProxySnapshot.ProxyValue, kind: String, service: String) -> [String] {
        var result: [String] = []
        if !value.server.isEmpty && value.port > 0 {
            result.append("\(command) -set\(kind) \(service) \(shellQuote(value.server)) \(value.port) off")
        }
        result.append("\(command) -set\(kind)state \(service) \(value.enabled ? "on" : "off")")
        return result
    }

    private func run(_ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else { throw AeroRuntimeError.commandFailed(output) }
        return output
    }

    private func runPrivileged(_ shellCommand: String) throws {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "系统代理授权失败"
            throw AeroRuntimeError.commandFailed(message)
        }
    }

    private func runPrivilegedBatch(_ commands: [String]) throws {
        let guarded = commands.map { "\($0) || aero_result=1" }.joined(separator: "; ")
        try runPrivileged("aero_result=0; \(guarded); exit $aero_result")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func parseProxy(_ text: String) -> ProxySnapshot.ProxyValue {
        let values = keyValues(text)
        return .init(enabled: values["Enabled"]?.lowercased() == "yes", server: values["Server"] ?? "", port: Int(values["Port"] ?? "") ?? 0)
    }

    private func parseAutoProxy(_ text: String) -> ProxySnapshot.AutoProxyValue {
        let values = keyValues(text)
        return .init(enabled: values["Enabled"]?.lowercased() == "yes", url: values["URL"] ?? "")
    }

    private func parseEnabled(_ text: String) -> Bool {
        text.lowercased().contains("on") || text.lowercased().contains("yes")
    }

    private func parseBypass(_ text: String) -> [String] {
        if text.localizedCaseInsensitiveContains("There aren't any") { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func keyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        text.split(whereSeparator: \.isNewline).forEach { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}

extension Notification.Name {
    static let aeroWillTerminate = Notification.Name("AeroWillTerminate")
}
