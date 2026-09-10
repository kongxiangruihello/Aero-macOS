import Foundation
import AppKit
import Darwin
import Security

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

    func start(executableURL: URL, configURL: URL, dataDirectory: URL, secret: String, controllerPort: Int, pidFileURL: URL, onOutput: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        stop()
        Self.cleanupStaleProcess(pidFileURL: pidFileURL)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
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
        let belongsToApp = command.contains("/Kong.app/Contents/Resources/mihomo") || command.contains("/Aero.app/Contents/Resources/mihomo")
        guard belongsToApp, command.contains("Application Support/Aero") else { return }
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
        request.timeoutInterval = path.hasPrefix("/providers/") ? 30 : 4
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

struct AeroBackupBundle: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let profiles: [Profile]
    let runtimeSettings: RuntimeSettings
    let files: [String: Data]
}

struct WebDAVClient: Sendable {
    func upload(_ data: Data, settings: WebDAVSettings, password: String) async throws {
        var request = try makeRequest(settings: settings, password: password, method: "PUT")
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: responseData)
    }

    func download(settings: WebDAVSettings, password: String) async throws -> Data {
        let request = try makeRequest(settings: settings, password: password, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard data.count <= 50_000_000 else {
            throw AeroRuntimeError.commandFailed("WebDAV 备份超过 50 MB")
        }
        return data
    }

    private func makeRequest(settings: WebDAVSettings, password: String, method: String) throws -> URLRequest {
        let raw = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: raw), ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw AeroRuntimeError.commandFailed("WebDAV 地址必须使用 HTTP 或 HTTPS")
        }
        let path = settings.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else {
            throw AeroRuntimeError.commandFailed("WebDAV 远程文件名无效")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !settings.username.isEmpty || !password.isEmpty {
            let credential = Data("\(settings.username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("Kong/1.3 WebDAV", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AeroRuntimeError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(data: data.prefix(1_000), encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AeroRuntimeError.commandFailed("WebDAV 返回 HTTP \(http.statusCode)：\(detail)")
        }
    }
}

final class WebDAVCredentialStore: @unchecked Sendable {
    private let service = "com.aero.networkconsole.webdav"
    private let account = "default"

    func loadPassword() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func savePassword(_ password: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(key as CFDictionary)
        guard !password.isEmpty else { return }
        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AeroRuntimeError.commandFailed("无法将 WebDAV 密码写入钥匙串（\(status)）")
        }
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
    let backupsDirectory: URL
    let metadataURL: URL
    let secretURL: URL
    let defaultProfileURL: URL
    let runtimeConfigURL: URL
    let pacURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("Aero", isDirectory: true)
        profilesDirectory = root.appendingPathComponent("Profiles", isDirectory: true)
        providersDirectory = root.appendingPathComponent("Providers", isDirectory: true)
        backupsDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        metadataURL = root.appendingPathComponent("profiles.json")
        secretURL = root.appendingPathComponent("controller.secret")
        defaultProfileURL = profilesDirectory.appendingPathComponent("default.yaml")
        runtimeConfigURL = root.appendingPathComponent("runtime.yaml")
        pacURL = root.appendingPathComponent("aero.pac")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providersDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
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

    func prepareRuntimeConfig(for profile: Profile, settings: RuntimeSettings, tunEnabled: Bool, coreURL: URL) throws -> URL {
        let base = try Data(contentsOf: fileURL(for: profile))
        let rendered = try RuntimeConfigOverlay.render(baseData: base, settings: settings, tunEnabled: tunEnabled)
        try rendered.write(to: runtimeConfigURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeConfigURL.path)
        try validate(configURL: runtimeConfigURL, coreURL: coreURL)
        return runtimeConfigURL
    }

    func writePAC(httpPort: Int, socksPort: Int) throws -> URL {
        let script = """
        function FindProxyForURL(url, host) {
          if (isPlainHostName(host) || dnsDomainIs(host, ".local") ||
              isInNet(host, "127.0.0.0", "255.0.0.0") ||
              isInNet(host, "10.0.0.0", "255.0.0.0") ||
              isInNet(host, "172.16.0.0", "255.240.0.0") ||
              isInNet(host, "192.168.0.0", "255.255.0.0")) return "DIRECT";
          return "PROXY 127.0.0.1:\(httpPort); SOCKS5 127.0.0.1:\(socksPort); DIRECT";
        }
        """
        try script.write(to: pacURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pacURL.path)
        return pacURL
    }

    func backup(_ profile: Profile) throws {
        let source = fileURL(for: profile)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = "\(profile.id)-"
        let destination = backupsDirectory.appendingPathComponent("\(prefix)\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).yaml")
        try FileManager.default.copyItem(at: source, to: destination)
        let backups = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            } ?? []
        for expired in backups.dropFirst(5) { try? FileManager.default.removeItem(at: expired) }
    }

    func makeBackupBundle(profiles: [Profile], settings: RuntimeSettings) throws -> AeroBackupBundle {
        var files: [String: Data] = [:]
        for profile in profiles {
            guard isSafeFileName(profile.fileName) else {
                throw AeroRuntimeError.commandFailed("配置文件名不安全：\(profile.fileName)")
            }
            files["Profiles/\(profile.fileName)"] = try Data(contentsOf: fileURL(for: profile))
            if let payload = profile.payloadFileName {
                guard isSafeFileName(payload) else {
                    throw AeroRuntimeError.commandFailed("Provider 文件名不安全：\(payload)")
                }
                let providerURL = providersDirectory.appendingPathComponent(payload)
                if FileManager.default.fileExists(atPath: providerURL.path) {
                    files["Providers/\(payload)"] = try Data(contentsOf: providerURL)
                }
            }
        }
        let providerFiles = (try? FileManager.default.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for providerURL in providerFiles where isSafeFileName(providerURL.lastPathComponent) {
            let values = try? providerURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files["Providers/\(providerURL.lastPathComponent)"] = try Data(contentsOf: providerURL)
            }
        }
        return AeroBackupBundle(schemaVersion: 1, generatedAt: Date(), profiles: profiles, runtimeSettings: settings, files: files)
    }

    func restoreBackup(_ bundle: AeroBackupBundle, coreURL: URL) throws -> ([Profile], RuntimeSettings) {
        guard bundle.schemaVersion == 1, !bundle.profiles.isEmpty else {
            throw AeroRuntimeError.commandFailed("WebDAV 备份格式或版本不受支持")
        }
        let staging = root.appendingPathComponent("Restore-\(UUID().uuidString)", isDirectory: true)
        let stagingProfiles = staging.appendingPathComponent("Profiles", isDirectory: true)
        let stagingProviders = staging.appendingPathComponent("Providers", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingProfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingProviders, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for profile in bundle.profiles {
            guard isSafeFileName(profile.fileName),
                  let data = bundle.files["Profiles/\(profile.fileName)"] else {
                throw AeroRuntimeError.commandFailed("备份缺少配置文件：\(profile.name)")
            }
            try data.write(to: stagingProfiles.appendingPathComponent(profile.fileName), options: .atomic)
            if let payload = profile.payloadFileName {
                guard isSafeFileName(payload), let providerData = bundle.files["Providers/\(payload)"] else {
                    throw AeroRuntimeError.commandFailed("备份缺少 Provider：\(payload)")
                }
                try providerData.write(to: stagingProviders.appendingPathComponent(payload), options: .atomic)
            }
        }
        for profile in bundle.profiles {
            try validate(configURL: stagingProfiles.appendingPathComponent(profile.fileName), coreURL: coreURL, dataDirectory: staging)
        }

        for existing in loadProfiles() { try? backup(existing) }
        for (relativePath, data) in bundle.files {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count == 2,
                  ["Profiles", "Providers"].contains(components[0]),
                  isSafeFileName(components[1]) else {
                throw AeroRuntimeError.commandFailed("备份包含不安全的文件路径")
            }
            let directory = components[0] == "Profiles" ? profilesDirectory : providersDirectory
            let destination = directory.appendingPathComponent(components[1])
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        try saveProfiles(bundle.profiles)
        return (bundle.profiles, bundle.runtimeSettings)
    }

    func validate(configURL: URL, coreURL: URL, dataDirectory: URL? = nil) throws {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = coreURL
        task.arguments = ["-t", "-d", (dataDirectory ?? root).path, "-f", configURL.path, "-ext-ctl", "127.0.0.1:0"]
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

    private func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent && value != "." && value != ".."
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

    func enablePAC(url: URL) throws {
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
                "\(command) -setwebproxystate \(service) off",
                "\(command) -setsecurewebproxystate \(service) off",
                "\(command) -setsocksfirewallproxystate \(service) off",
                "\(command) -setautoproxyurl \(service) \(shellQuote(url.absoluteString))",
                "\(command) -setautoproxystate \(service) on"
            ]
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

    func status(httpPort: Int, socksPort: Int, pacURL: URL) -> ProxyCaptureMode? {
        guard let output = try? run(["-listallnetworkservices"]) else { return nil }
        let services = output.split(whereSeparator: \.isNewline).dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
        for service in services {
            if let auto = try? run(["-getautoproxyurl", service]),
               parseAutoProxy(auto).enabled,
               parseAutoProxy(auto).url == pacURL.absoluteString { return .pac }
            if let web = try? run(["-getwebproxy", service]),
               let socks = try? run(["-getsocksfirewallproxy", service]) {
                let webValue = parseProxy(web)
                let socksValue = parseProxy(socks)
                if webValue.enabled, socksValue.enabled,
                   webValue.server == "127.0.0.1", socksValue.server == "127.0.0.1",
                   webValue.port == httpPort, socksValue.port == socksPort { return .system }
            }
        }
        return nil
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
