import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App model

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var selectedSection: SidebarSection = .overview
    @Published var isConnected = false
    @Published var isChangingConnection = false
    @Published var coreState: CoreState = .stopped
    @Published var coreVersion = "检测中"
    @Published var mode: ProxyMode = .rule
    @Published var selectedNodeID = "DIRECT"
    @Published var selectedProxyGroup = "节点选择"
    @Published var proxyGroups: [ProxyGroup] = []
    @Published var searchText = ""
    @Published var uploadRate = 0.0
    @Published var downloadRate = 0.0
    @Published var totalUpload = 0.0
    @Published var totalDownload = 0.0
    @Published var latencyTesting = false
    @Published var activity: [Double] = Array(repeating: 0.03, count: 18)
    @Published var logs: [LogEntry] = []
    @Published var profiles: [Profile] = []
    @Published var activeProfileID = "default"
    @Published var showImportSheet = false
    @Published var showCommandPalette = false
    @Published var showInspector = false
    @Published var toast: String?
    @Published var alertMessage: String?
    @Published var httpPort = 7890
    @Published var socksPort = 7890

    @Published var nodes: [ProxyNode] = []
    @Published var connections: [ConnectionItem] = []
    @Published var rules: [RuleItem] = []

    private var timer: Timer?
    private let repository: ProfileRepository
    private let core = MihomoProcess()
    private let api: MihomoAPI
    private let controllerPort: Int
    private let systemProxy: SystemProxyManager
    private var refreshCounter = 0
    private var isRefreshing = false
    private var lastTrafficDate = Date()
    private var lastUploadBytes: Double = 0
    private var lastDownloadBytes: Double = 0

    override init() {
        let repository = ProfileRepository()
        try? repository.prepare()
        let secret = (try? repository.loadOrCreateSecret()) ?? "aero-local-controller"
        MihomoProcess.cleanupStaleProcess(pidFileURL: repository.root.appendingPathComponent("mihomo.pid"))
        let controllerPort = LocalPort.firstAvailable(startingAt: 19097)
        self.repository = repository
        self.controllerPort = controllerPort
        self.api = MihomoAPI(secret: secret, port: controllerPort)
        self.systemProxy = SystemProxyManager(appSupportDirectory: repository.root)
        let loadedProfiles = repository.loadProfiles()
        self.profiles = loadedProfiles
        let savedID = UserDefaults.standard.string(forKey: "activeProfileID") ?? "default"
        self.activeProfileID = loadedProfiles.contains(where: { $0.id == savedID }) ? savedID : "default"
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRuntime() }
        }
        Task { await startCore() }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    var selectedNode: ProxyNode {
        nodes.first(where: { $0.id == selectedNodeID }) ?? nodes.first ?? .placeholder
    }

    var activeConnections: [ConnectionItem] {
        connections.filter { $0.status == .active }
    }

    var modeBinding: Binding<ProxyMode> {
        Binding(get: { self.mode }, set: { self.setMode($0) })
    }

    func startCore() async {
        guard coreState != .starting else { return }
        coreState = .starting
        do {
            coreState = .stopped
            core.stop()
            coreState = .starting
            let savedPort = UserDefaults.standard.integer(forKey: "runtimeProxyPort")
            let preferredPort = savedPort > 0 ? savedPort : 17890
            let runtimePort = LocalPort.isAvailable(preferredPort) ? preferredPort : LocalPort.firstAvailable()
            UserDefaults.standard.set(runtimePort, forKey: "runtimeProxyPort")
            httpPort = runtimePort
            socksPort = runtimePort
            recordDiagnostic("selected-port=\(runtimePort)")
            try repository.prepare()
            guard let profile = profiles.first(where: { $0.id == activeProfileID }) else { throw AeroRuntimeError.missingProfile }
            let configURL = repository.fileURL(for: profile)
            try core.start(configURL: configURL, dataDirectory: repository.root, secret: api.secret, controllerPort: controllerPort, pidFileURL: repository.root.appendingPathComponent("mihomo.pid"), onOutput: { [weak self] line in
                Task { @MainActor in self?.appendCoreLog(line) }
            }, onExit: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.coreState != .stopped else { return }
                    self.coreState = status == 0 ? .stopped : .failed("Mihomo 已退出，代码 \(status)")
                    self.isConnected = false
                }
            })
            try await api.waitUntilReady()
            _ = try await api.request("/configs", method: "PATCH", json: ["mixed-port": runtimePort])
            try await Task.sleep(nanoseconds: 180_000_000)
            let runtimeConfigData = try await api.request("/configs")
            recordDiagnostic("runtime-config=\(String(data: runtimeConfigData, encoding: .utf8) ?? "unreadable")")
            guard let runtimeConfig = try JSONSerialization.jsonObject(with: runtimeConfigData) as? [String: Any],
                  (runtimeConfig["mixed-port"] as? NSNumber)?.intValue == runtimePort else {
                throw AeroRuntimeError.commandFailed("无法启用独立代理端口 \(runtimePort)")
            }
            coreState = .running
            let versionData = try await api.request("/version")
            if let json = try JSONSerialization.jsonObject(with: versionData) as? [String: Any] {
                coreVersion = (json["version"] as? String) ?? "v1.19.30"
            }
            await refreshRuntime(force: true)
            if systemProxy.hasActiveSnapshot {
                let appliedPort = UserDefaults.standard.integer(forKey: "systemProxyAppliedPort")
                if appliedPort == runtimePort {
                    isConnected = true
                } else {
                    showToast("代理端口已变化，需要重新授权系统代理")
                    await setConnectionEnabled(true)
                }
            }
            showToast("Mihomo \(coreVersion) 已启动")
        } catch {
            recordDiagnostic("startup-error=\(error.localizedDescription)")
            coreState = .failed(error.localizedDescription)
            appendLog(level: "ERROR", message: error.localizedDescription)
            showToast("内核启动失败：\(error.localizedDescription)")
        }
    }

    func testLatency() {
        guard !latencyTesting, coreState == .running else { return }
        latencyTesting = true
        showToast("正在测试全部节点…")
        Task {
            do {
                let group = selectedProxyGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedProxyGroup
                let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
                _ = try await api.request("/group/\(group)/delay?url=\(testURL)&timeout=5000")
                await refreshProxies()
                latencyTesting = false
                let available = nodes.filter { $0.latency > 0 }.count
                showToast("测速完成 · \(available) 个节点可用")
            } catch {
                latencyTesting = false
                showToast("测速失败：\(error.localizedDescription)")
            }
        }
    }

    func toggleConnection() {
        guard !isChangingConnection else { return }
        Task { await setConnectionEnabled(!isConnected) }
    }

    func setConnectionEnabled(_ enabled: Bool) async {
        guard !isChangingConnection else { return }
        if enabled && coreState != .running {
            await startCore()
            guard coreState == .running else { return }
        }
        isChangingConnection = true
        do {
            let proxy = systemProxy
            if enabled {
                let web = httpPort
                let socks = socksPort
                try await Task.detached { try proxy.enable(httpPort: web, socksPort: socks) }.value
                UserDefaults.standard.set(web, forKey: "systemProxyAppliedPort")
            } else {
                try await Task.detached { try proxy.disable() }.value
                UserDefaults.standard.removeObject(forKey: "systemProxyAppliedPort")
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isConnected = enabled }
            showToast(enabled ? "系统代理已开启" : "系统代理已恢复")
        } catch {
            showToast("系统代理设置失败：\(error.localizedDescription)")
            appendLog(level: "ERROR", message: error.localizedDescription)
        }
        isChangingConnection = false
    }

    func setMode(_ newMode: ProxyMode) {
        guard mode != newMode else { return }
        mode = newMode
        Task {
            do {
                _ = try await api.request("/configs", method: "PATCH", json: ["mode": newMode.apiValue])
                showToast("已切换至\(newMode.rawValue)模式")
            } catch {
                showToast("模式切换失败：\(error.localizedDescription)")
            }
        }
    }

    func selectNode(_ node: ProxyNode) {
        guard node.id != selectedNodeID else { return }
        let previous = selectedNodeID
        selectedNodeID = node.id
        Task {
            do {
                let group = selectedProxyGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedProxyGroup
                _ = try await api.request("/proxies/\(group)", method: "PUT", json: ["name": node.name])
                showToast("已切换至 \(node.name)")
                await refreshProxies()
            } catch {
                selectedNodeID = previous
                showToast("节点切换失败：\(error.localizedDescription)")
            }
        }
    }

    func selectProxyGroup(_ name: String) {
        selectedProxyGroup = name
        applySelectedGroup()
    }

    func closeAllConnections() {
        Task {
            do {
                _ = try await api.request("/connections", method: "DELETE")
                connections.removeAll()
                showToast("已关闭全部活动连接")
            } catch { showToast("关闭失败：\(error.localizedDescription)") }
        }
    }

    func activateProfile(_ profile: Profile) {
        guard profile.id != activeProfileID else { return }
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "activeProfileID")
        Task {
            await startCore()
            showToast("已应用配置“\(profile.name)”")
        }
    }

    func importProfile(from urlString: String) {
        guard let url = SubscriptionDownloader.normalizedURL(from: urlString) else {
            presentError("无法添加订阅", SubscriptionDownloadError.invalidURL)
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url)
                let name = subscriptionName(from: response) ?? url.host ?? "订阅配置"
                try installProfile(data: data, name: name, remoteURL: url.absoluteString)
            } catch { presentError("添加订阅失败", error) }
        }
    }

    func importLocalProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mihomo / Clash 配置"
        panel.allowedContentTypes = [.data, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try installProfile(data: data, name: url.deletingPathExtension().lastPathComponent, remoteURL: nil)
        } catch { presentError("导入配置失败", error) }
    }

    func updateProfile(_ profile: Profile) {
        guard let remote = profile.remoteURL, let url = URL(string: remote) else {
            showToast("本地配置没有远程更新地址")
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url)
                try replaceProfile(profile, with: data, response: response)
                showToast("“\(profile.name)”已更新")
                if profile.id == activeProfileID { await startCore() }
            } catch { presentError("更新订阅失败", error) }
        }
    }

    private func installProfile(data: Data, name: String, remoteURL: String?) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).yaml"
        let destination = repository.profilesDirectory.appendingPathComponent(fileName)
        let temporary = repository.root.appendingPathComponent("import-\(id).yaml")
        let prepared = try SubscriptionFormatter.prepare(data: data, id: id)
        var installedProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? FileManager.default.removeItem(at: destination)
                if let installedProviderURL { try? FileManager.default.removeItem(at: installedProviderURL) }
            }
        }
        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            installedProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let source = remoteURL == nil ? "\(prepared.label) · 本地配置" : "\(prepared.label) · 远程订阅"
        let profile = Profile(id: id, name: name, source: source, updated: "刚刚更新", size: size, fileName: fileName, remoteURL: remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        let updatedProfiles = profiles + [profile]
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        committed = true
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: "activeProfileID")
        Task { await startCore() }
        let nodeSummary = prepared.nodeCount.map { " · \($0) 个节点" } ?? ""
        showToast("配置校验通过并已导入\(nodeSummary)")
    }

    private func replaceProfile(_ profile: Profile, with data: Data, response: HTTPURLResponse) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let prepared = try SubscriptionFormatter.prepare(data: data, id: profile.id)
        let destination = repository.fileURL(for: profile)
        let temporary = repository.root.appendingPathComponent("update-\(UUID().uuidString).yaml")
        let previousConfig = try Data(contentsOf: destination)
        let oldProviderURL = profile.payloadFileName.map { repository.providersDirectory.appendingPathComponent($0) }
        let previousProvider = oldProviderURL.flatMap { try? Data(contentsOf: $0) }
        var newProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? previousConfig.write(to: destination, options: .atomic)
                if let newProviderURL {
                    if newProviderURL == oldProviderURL, let previousProvider {
                        try? previousProvider.write(to: newProviderURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: newProviderURL)
                    }
                }
            }
        }

        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            newProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)

        let displayName = subscriptionName(from: response) ?? profile.name
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let updated = Profile(id: profile.id, name: displayName, source: "\(prepared.label) · 远程订阅", updated: "刚刚更新", size: size, fileName: profile.fileName, remoteURL: profile.remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw AeroRuntimeError.missingProfile }
        var updatedProfiles = profiles
        updatedProfiles[index] = updated
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        committed = true
        if let oldProviderURL, oldProviderURL != newProviderURL { try? FileManager.default.removeItem(at: oldProviderURL) }
    }

    private func downloadSubscription(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await SubscriptionDownloader.download(from: url)
        recordDiagnostic("subscription-client-profile=\(result.clientProfile)")
        return (result.data, result.response)
    }

    private func subscriptionName(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "profile-title")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let decoded = raw.removingPercentEncoding, !decoded.isEmpty { return String(decoded.prefix(80)) }
        return String(raw.prefix(80))
    }

    private func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func refreshRuntime(force: Bool = false) async {
        guard coreState == .running, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshCounter += 1
        do {
            try await refreshConnections()
            if force || refreshCounter % 3 == 0 { await refreshProxies() }
            if force || refreshCounter % 10 == 0 { try await refreshRulesAndConfig() }
        } catch {
            if core.isRunning == false { coreState = .failed(error.localizedDescription) }
        }
    }

    private func refreshConnections() async throws {
        let data = try await api.request("/connections")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AeroRuntimeError.invalidResponse }
        let uploadBytes = (root["uploadTotal"] as? NSNumber)?.doubleValue ?? 0
        let downloadBytes = (root["downloadTotal"] as? NSNumber)?.doubleValue ?? 0
        let now = Date()
        let elapsed = max(0.25, now.timeIntervalSince(lastTrafficDate))
        if lastUploadBytes > 0 {
            uploadRate = max(0, uploadBytes - lastUploadBytes) / elapsed / 1_048_576
            downloadRate = max(0, downloadBytes - lastDownloadBytes) / elapsed / 1_048_576
        }
        lastUploadBytes = uploadBytes
        lastDownloadBytes = downloadBytes
        lastTrafficDate = now
        totalUpload = uploadBytes / 1_073_741_824
        totalDownload = downloadBytes / 1_073_741_824
        activity.removeFirst()
        activity.append(min(1, downloadRate / 20))

        let rawConnections = root["connections"] as? [[String: Any]] ?? []
        connections = rawConnections.prefix(250).map { raw in
            let metadata = raw["metadata"] as? [String: Any] ?? [:]
            let host = (metadata["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (metadata["destinationIP"] as? String) ?? "未知目标"
            let processPath = (metadata["processPath"] as? String) ?? (metadata["process"] as? String) ?? "网络进程"
            let appName = URL(fileURLWithPath: processPath).deletingPathExtension().lastPathComponent
            let chains = raw["chains"] as? [String] ?? []
            let rule = raw["rule"] as? String ?? "MATCH"
            return ConnectionItem(
                id: raw["id"] as? String ?? UUID().uuidString,
                app: appName.isEmpty ? "网络进程" : appName,
                symbol: symbol(for: appName),
                host: host,
                network: (metadata["network"] as? String ?? "TCP").uppercased(),
                upload: formatBytes((raw["upload"] as? NSNumber)?.int64Value ?? 0),
                download: formatBytes((raw["download"] as? NSNumber)?.int64Value ?? 0),
                rule: "\(rule) → \(chains.first ?? "DIRECT")",
                status: .active
            )
        }
    }

    private func refreshProxies() async {
        do {
            let data = try await api.request("/proxies")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rawProxies = root["proxies"] as? [String: [String: Any]] else { throw AeroRuntimeError.invalidResponse }
            let groupTypes = Set(["Selector", "URLTest", "Fallback", "LoadBalance"])
            let groups = rawProxies.values.compactMap { raw -> ProxyGroup? in
                guard let name = raw["name"] as? String, let type = raw["type"] as? String, groupTypes.contains(type), raw["hidden"] as? Bool != true else { return nil }
                return ProxyGroup(name: name, type: type, now: raw["now"] as? String ?? raw["fixed"] as? String ?? "", members: raw["all"] as? [String] ?? [])
            }.sorted { lhs, rhs in
                if lhs.name == "GLOBAL" { return false }
                if rhs.name == "GLOBAL" { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            proxyGroups = groups
            if !groups.contains(where: { $0.name == selectedProxyGroup }) {
                selectedProxyGroup = groups.first?.name ?? "GLOBAL"
            }
            applySelectedGroup(from: rawProxies)
        } catch {
            appendLog(level: "WARN", message: "读取代理节点失败：\(error.localizedDescription)")
        }
    }

    private func applySelectedGroup(from proxies: [String: [String: Any]]? = nil) {
        guard let group = proxyGroups.first(where: { $0.name == selectedProxyGroup }) else {
            nodes = []; return
        }
        selectedNodeID = group.now
        guard let proxies else { Task { await refreshProxies() }; return }
        nodes = group.members.compactMap { name in
            guard let raw = proxies[name] else { return nil }
            let history = raw["history"] as? [[String: Any]] ?? []
            let latency = (history.last?["delay"] as? NSNumber)?.intValue ?? 0
            let type = raw["type"] as? String ?? "Proxy"
            return ProxyNode(id: name, name: name, city: type, countryCode: flag(for: name), latency: latency, load: latency == 0 ? 0 : min(1, Double(latency) / 500), type: type, favorite: name == group.now)
        }
    }

    private func refreshRulesAndConfig() async throws {
        let configData = try await api.request("/configs")
        if let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            let mixed = (config["mixed-port"] as? NSNumber)?.intValue ?? 0
            let web = (config["port"] as? NSNumber)?.intValue ?? 0
            let socks = (config["socks-port"] as? NSNumber)?.intValue ?? 0
            httpPort = mixed > 0 ? mixed : (web > 0 ? web : 7890)
            socksPort = mixed > 0 ? mixed : (socks > 0 ? socks : httpPort)
            if let apiMode = config["mode"] as? String, let parsed = ProxyMode(apiValue: apiMode) { mode = parsed }
        }
        let rulesData = try await api.request("/rules")
        if let root = try JSONSerialization.jsonObject(with: rulesData) as? [String: Any], let rawRules = root["rules"] as? [[String: Any]] {
            rules = rawRules.prefix(500).map { raw in
                let extra = raw["extra"] as? [String: Any]
                return RuleItem(
                    id: String((raw["index"] as? NSNumber)?.intValue ?? 0),
                    type: raw["type"] as? String ?? "MATCH",
                    payload: raw["payload"] as? String ?? "*",
                    policy: raw["proxy"] as? String ?? "DIRECT",
                    matches: (extra?["hitCount"] as? NSNumber)?.intValue ?? 0
                )
            }
        }
    }

    private func appendCoreLog(_ line: String) {
        let lower = line.lowercased()
        let level = lower.contains("error") ? "ERROR" : lower.contains("warn") ? "WARN" : lower.contains("debug") ? "DEBUG" : "INFO"
        appendLog(level: level, message: line)
    }

    private func appendLog(level: String, message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append(LogEntry(time: formatter.string(from: Date()), level: level, message: message))
        if logs.count > 1_000 { logs.removeFirst(logs.count - 1_000) }
    }

    private func flag(for name: String) -> String {
        let lower = name.lowercased()
        let pairs = [("香港", "🇭🇰"), ("hong kong", "🇭🇰"), ("日本", "🇯🇵"), ("东京", "🇯🇵"), ("japan", "🇯🇵"), ("新加坡", "🇸🇬"), ("狮城", "🇸🇬"), ("singapore", "🇸🇬"), ("美国", "🇺🇸"), ("united states", "🇺🇸"), ("洛杉矶", "🇺🇸"), ("台湾", "🇹🇼"), ("taiwan", "🇹🇼"), ("英国", "🇬🇧"), ("伦敦", "🇬🇧"), ("德国", "🇩🇪"), ("韩国", "🇰🇷")]
        return pairs.first(where: { lower.contains($0.0) })?.1 ?? (name == "DIRECT" ? "🖥" : "🌐")
    }

    private func symbol(for app: String) -> String {
        let lower = app.lowercased()
        if lower.contains("safari") { return "safari.fill" }
        if lower.contains("telegram") { return "paperplane.fill" }
        if lower.contains("music") { return "music.note" }
        return "app.fill"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func recordDiagnostic(_ message: String) {
        let url = repository.root.appendingPathComponent("last-start.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let detail = String(error.localizedDescription.prefix(1_200))
        let diagnostic = detail.replacingOccurrences(of: "\n", with: " ")
        recordDiagnostic("subscription-error=\(diagnostic)")
        appendLog(level: "ERROR", message: "\(title)：\(detail)")
        alertMessage = "\(title)：\n\n\(detail)"
    }

    @objc private func applicationWillTerminate() {
        if systemProxy.hasActiveSnapshot, (try? systemProxy.disable()) != nil {
            UserDefaults.standard.removeObject(forKey: "systemProxyAppliedPort")
        }
        coreState = .stopped
        core.stop()
    }

    func showToast(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case proxies = "代理"
    case connections = "连接"
    case rules = "规则"
    case profiles = "配置"
    case logs = "日志"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .proxies: return "point.3.connected.trianglepath.dotted"
        case .connections: return "arrow.triangle.branch"
        case .rules: return "list.bullet.rectangle.portrait"
        case .profiles: return "doc.on.doc.fill"
        case .logs: return "terminal.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule = "规则"
    case global = "全局"
    case direct = "直连"
    var id: String { rawValue }
    var apiValue: String {
        switch self {
        case .rule: return "rule"
        case .global: return "global"
        case .direct: return "direct"
        }
    }

    init?(apiValue: String) {
        switch apiValue.lowercased() {
        case "rule": self = .rule
        case "global": self = .global
        case "direct": self = .direct
        default: return nil
        }
    }
}

struct ProxyNode: Identifiable, Hashable {
    let id: String
    let name: String
    let city: String
    let countryCode: String
    let latency: Int
    let load: Double
    let type: String
    let favorite: Bool

    static let placeholder = ProxyNode(id: "DIRECT", name: "DIRECT", city: "等待内核", countryCode: "🖥", latency: 0, load: 0, type: "Direct", favorite: false)

    static let sample: [ProxyNode] = [
        .init(id: "auto", name: "自动选择", city: "智能路由", countryCode: "⚡️", latency: 42, load: 0.31, type: "URL-Test", favorite: true),
        .init(id: "sg-01", name: "狮城 · 01", city: "Singapore", countryCode: "🇸🇬", latency: 58, load: 0.42, type: "VLESS", favorite: true),
        .init(id: "jp-02", name: "东京 · 02", city: "Tokyo", countryCode: "🇯🇵", latency: 76, load: 0.61, type: "Hysteria2", favorite: true),
        .init(id: "hk-03", name: "香港 · 03", city: "Hong Kong", countryCode: "🇭🇰", latency: 84, load: 0.54, type: "Trojan", favorite: false),
        .init(id: "us-01", name: "洛杉矶 · 01", city: "Los Angeles", countryCode: "🇺🇸", latency: 168, load: 0.72, type: "VLESS", favorite: false),
        .init(id: "de-01", name: "法兰克福 · 01", city: "Frankfurt", countryCode: "🇩🇪", latency: 212, load: 0.36, type: "Shadowsocks", favorite: false),
        .init(id: "uk-01", name: "伦敦 · 01", city: "London", countryCode: "🇬🇧", latency: 238, load: 0.83, type: "Trojan", favorite: false)
    ]
}

struct ProxyGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let now: String
    let members: [String]
}

enum ConnectionStatus { case active, idle }

struct ConnectionItem: Identifiable {
    let id: String
    let app: String
    let symbol: String
    let host: String
    let network: String
    let upload: String
    let download: String
    let rule: String
    let status: ConnectionStatus

    static let sample: [ConnectionItem] = [
        .init(id: "sample-1", app: "Safari", symbol: "safari.fill", host: "www.apple.com", network: "TCP", upload: "24 KB", download: "1.8 MB", rule: "Apple → DIRECT", status: .active)
    ]
}

struct RuleItem: Identifiable {
    let id: String
    let type: String
    let payload: String
    let policy: String
    let matches: Int

    static let sample: [RuleItem] = [
        .init(id: "0", type: "MATCH", payload: "*", policy: "DIRECT", matches: 0)
    ]
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let level: String
    let message: String

    static let sample: [LogEntry] = [
        .init(time: "23:41:28", level: "INFO", message: "[TCP] 127.0.0.1:52182 → github.com:443 match DomainKeyword(github) using 节点选择[狮城 · 01]"),
        .init(time: "23:41:26", level: "INFO", message: "[UDP] 127.0.0.1:59214 → gateway.icloud.com:443 match DomainSuffix(apple.com) using DIRECT"),
        .init(time: "23:41:24", level: "DEBUG", message: "DNS response cache hit: api.telegram.org → 149.154.167.220"),
        .init(time: "23:41:18", level: "INFO", message: "[TCP] 127.0.0.1:52160 → audio-ssl.itunes.apple.com:443 using 媒体服务[狮城 · 01]"),
        .init(time: "23:41:04", level: "WARN", message: "Health check: 洛杉矶 · 01 latency increased to 168 ms"),
        .init(time: "23:40:58", level: "INFO", message: "Profile “默认配置” updated successfully")
    ]
}

struct Profile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let source: String
    let updated: String
    let size: String
    let fileName: String
    let remoteURL: String?
    let format: String?
    let payloadFileName: String?

    static let sample: [Profile] = [
        .init(id: "default", name: "默认直连配置", source: "内置安全配置", updated: "随应用提供", size: "1 KB", fileName: "default.yaml", remoteURL: nil, format: "builtin", payloadFileName: nil)
    ]
}

// MARK: - Theme

enum Theme {
    static let bg = Color(red: 0.055, green: 0.065, blue: 0.09)
    static let panel = Color.white.opacity(0.055)
    static let panelStrong = Color.white.opacity(0.085)
    static let stroke = Color.white.opacity(0.09)
    static let text = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let secondary = Color(red: 0.56, green: 0.60, blue: 0.68)
    static let accent = Color(red: 0.45, green: 0.88, blue: 0.72)
    static let accent2 = Color(red: 0.36, green: 0.58, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.34)
    static let danger = Color(red: 1.0, green: 0.39, blue: 0.46)
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

extension View {
    func card(_ padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }
}

// MARK: - App

@main
struct AeroClashApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandMenu("Aero") {
                Button(model.isConnected ? "关闭系统代理" : "开启系统代理") { model.toggleConnection() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("打开命令面板") { model.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra("AeroClash", systemImage: model.isConnected ? "shield.lefthalf.filled" : "shield") {
            MenuBarContent()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 218)
                Divider().overlay(Theme.stroke)
                ZStack {
                    switch model.selectedSection {
                    case .overview: OverviewView()
                    case .proxies: ProxiesView()
                    case .connections: ConnectionsView()
                    case .rules: RulesView()
                    case .profiles: ProfilesView()
                    case .logs: LogsView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.showCommandPalette { CommandPalette() }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.stroke))
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $model.showImportSheet) { ImportProfileSheet() }
        .alert("操作失败", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "wind").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.black.opacity(0.72))
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aero").font(.system(size: 17, weight: .bold))
                    Text("网络控制台").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 18)
            .padding(.bottom, 22)

            VStack(spacing: 4) {
                ForEach(SidebarSection.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.selectedSection = section }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.icon).frame(width: 20)
                            Text(section.rawValue).font(.system(size: 13, weight: .medium))
                            Spacer()
                            if section == .connections {
                                Text("\(model.connections.count)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.15)).foregroundStyle(Theme.accent).clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(model.selectedSection == section ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(model.selectedSection == section ? Theme.panelStrong : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 7) {
                        Circle().fill(model.coreState == .running ? Theme.accent : model.coreState == .starting ? Theme.warning : Theme.secondary).frame(width: 7, height: 7)
                        Text(model.coreState.label).font(.system(size: 11, weight: .medium))
                    }
                    Spacer()
                    Text("v1.1").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedNode.name).font(.system(size: 12, weight: .semibold))
                        Text("\(model.selectedNode.latency) ms · \(model.selectedNode.type)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(model.selectedNode.countryCode).font(.system(size: 18))
                }
            }
            .padding(13)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
        .background(Color.black.opacity(0.13))
    }
}

// MARK: - Shared components

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : Theme.text)
                .padding(.horizontal, 13).frame(height: 34)
                .background(active ? Theme.accent : Theme.panelStrong)
                .clipShape(Capsule()).overlay(Capsule().stroke(active ? Color.clear : Theme.stroke))
        }.buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).frame(height: 34).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }
}

struct ModePicker: View {
    @Binding var selection: ProxyMode
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProxyMode.allCases) { mode in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = mode } } label: {
                    Text(mode.rawValue).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(selection == mode ? Theme.text : Theme.secondary)
                        .background(selection == mode ? Color.white.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(Color.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }
}

struct StatusBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggleConnection() } label: {
            HStack(spacing: 8) {
                Circle().fill(model.isConnected ? Theme.accent : Theme.secondary).frame(width: 7, height: 7).shadow(color: model.isConnected ? Theme.accent.opacity(0.8) : .clear, radius: 5)
                Text(model.isChangingConnection ? "处理中" : model.isConnected ? "已连接" : "未连接").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 13).frame(height: 34).background(Theme.panelStrong).clipShape(Capsule()).overlay(Capsule().stroke(Theme.stroke))
        }.buttonStyle(.plain).disabled(model.isChangingConnection)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "晚上好", subtitle: model.coreState == .running ? "Mihomo 内核运行正常" : model.coreState.label) { StatusBadge() }
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        ConnectionHero().frame(maxWidth: .infinity)
                        TrafficCard().frame(maxWidth: .infinity)
                    }.frame(height: 270)
                    HStack(spacing: 16) {
                        QuickStat(icon: "arrow.up", label: "今日上传", value: String(format: "%.1f GB", model.totalUpload), tint: Theme.accent2)
                        QuickStat(icon: "arrow.down", label: "今日下载", value: String(format: "%.1f GB", model.totalDownload), tint: Theme.accent)
                        QuickStat(icon: "bolt.fill", label: "活动连接", value: "\(model.activeConnections.count)", tint: Theme.warning)
                        QuickStat(icon: "clock.fill", label: "运行时间", value: "06:42:18", tint: Color.purple.opacity(0.9))
                    }
                    HStack(alignment: .top, spacing: 16) {
                        QuickActions().frame(maxWidth: .infinity)
                        RecentConnections().frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 30).padding(.bottom, 28)
            }
        }
    }
}

struct ConnectionHero: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            HStack { SectionTitle(title: "系统代理", detail: model.isConnected ? "保护中" : "已暂停") }
            Spacer()
            Button { model.toggleConnection() } label: {
                ZStack {
                    Circle().fill(model.isConnected ? Theme.accent.opacity(0.14) : Color.white.opacity(0.06)).frame(width: 112, height: 112)
                    Circle().stroke(model.isConnected ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: 1).frame(width: 90, height: 90)
                    Image(systemName: model.isConnected ? "power" : "power").font(.system(size: 34, weight: .medium)).foregroundStyle(model.isConnected ? Theme.accent : Theme.secondary)
                }
            }.buttonStyle(.plain)
            VStack(spacing: 4) {
                Text(model.isConnected ? "连接已开启" : "点击以连接").font(.system(size: 15, weight: .bold))
                Text(model.isConnected ? "流量正在由 Aero 安全转发" : "当前使用系统网络设置").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }.card()
    }
}

struct TrafficCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "实时速率", detail: "最近 30 秒")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(String(format: "%.2f", model.downloadRate)).font(.system(size: 34, weight: .bold, design: .rounded))
                Text("MB/s").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Label(String(format: "%.2f MB/s", model.uploadRate), systemImage: "arrow.up").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent2)
                    Text("上传").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            ActivityChart(values: model.activity).frame(height: 115)
        }.card()
    }
}

struct ActivityChart: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Path { p in
                    for i in 0..<4 {
                        let y = geo.size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }.stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                let points = values.enumerated().map { index, value in
                    CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)), y: geo.size.height * (1 - CGFloat(value) * 0.88))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height)); p.addLine(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                    if let last = points.last { p.addLine(to: CGPoint(x: last.x, y: geo.size.height)) }
                    p.closeSubpath()
                }.fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }; p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct QuickStat: View {
    let icon: String, label: String, value: String, tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(tint).frame(width: 34, height: 34).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary); Text(value).font(.system(size: 14, weight: .bold)) }
            Spacer(minLength: 0)
        }.card(14)
    }
}

struct QuickActions: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            SectionTitle(title: "快速控制")
            ModePicker(selection: model.modeBinding)
            HStack(spacing: 10) {
                ActionTile(icon: "scope", title: "节点测速", subtitle: model.latencyTesting ? "测速中…" : "全部节点", tint: Theme.accent) { model.testLatency() }
                ActionTile(icon: "arrow.clockwise", title: "更新配置", subtitle: "当前订阅", tint: Theme.accent2) {
                    if let profile = model.profiles.first(where: { $0.id == model.activeProfileID }) { model.updateProfile(profile) }
                }
                ActionTile(icon: "hammer.fill", title: "诊断网络", subtitle: "状态良好", tint: Theme.warning) { model.showToast("网络诊断完成 · 未发现问题") }
            }
        }.card()
    }
}

struct ActionTile: View {
    let icon: String, title: String, subtitle: String, tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 11, weight: .semibold)); Text(subtitle).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.black.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.stroke))
        }.buttonStyle(.plain)
    }
}

struct RecentConnections: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 13) {
            SectionTitle(title: "最近连接", detail: "查看全部")
            ForEach(model.connections.prefix(3)) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 30, height: 30).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) { Text(item.host).font(.system(size: 11, weight: .medium)).lineLimit(1); Text(item.rule).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    Spacer(); Text(item.download).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
        }.card()
    }
}

// MARK: - Proxies

struct ProxiesView: View {
    @EnvironmentObject var model: AppModel
    var filtered: [ProxyNode] { model.nodes.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.city.localizedCaseInsensitiveContains(model.searchText) } }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "代理", subtitle: "选择流量出口与策略组") {
                HStack(spacing: 10) {
                    PillButton(title: model.latencyTesting ? "测速中" : "全部测速", icon: "scope", action: model.testLatency)
                    StatusBadge()
                }
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("策略组").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                    ForEach(model.proxyGroups) { item in
                        Button { model.selectProxyGroup(item.name) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.type == "Selector" ? "point.3.filled.connected.trianglepath.dotted" : "bolt.fill").frame(width: 18).foregroundStyle(model.selectedProxyGroup == item.name ? Theme.accent : Theme.secondary)
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(); Text("\(item.members.count)").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                            }.padding(.horizontal, 11).frame(height: 38).background(model.selectedProxyGroup == item.name ? Theme.panelStrong : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if model.proxyGroups.isEmpty {
                        Text(model.coreState.label).font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(12)
                    }
                    Spacer()
                    ModePicker(selection: model.modeBinding).padding(10)
                }.frame(width: 190).padding(.leading, 18).padding(.bottom, 20)
                Divider().overlay(Theme.stroke)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(model.selectedProxyGroup).font(.system(size: 18, weight: .bold)); Text("当前：\(model.selectedNode.name)").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                        Spacer(); SearchField(text: $model.searchText, placeholder: "搜索节点").frame(width: 210)
                    }.padding(.horizontal, 22).padding(.bottom, 14)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { node in ProxyNodeCard(node: node) }
                        }.padding(.horizontal, 22).padding(.bottom, 24)
                    }
                }
            }
        }
    }
}

struct ProxyNodeCard: View {
    @EnvironmentObject var model: AppModel
    let node: ProxyNode
    var selected: Bool { model.selectedNodeID == node.id }
    var latencyColor: Color { node.latency < 90 ? Theme.accent : node.latency < 180 ? Theme.warning : Theme.danger }
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { model.selectNode(node) }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(node.countryCode).font(.system(size: 26)); Spacer()
                    if node.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.warning) }
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
                VStack(alignment: .leading, spacing: 3) { Text(node.name).font(.system(size: 14, weight: .bold)); Text("\(node.city) · \(node.type)").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                HStack {
                    Circle().fill(latencyColor).frame(width: 6, height: 6); Text("\(node.latency) ms").font(.system(size: 10, weight: .semibold)).foregroundStyle(latencyColor)
                    Spacer(); Text("负载 \(Int(node.load * 100))%").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.06)); Capsule().fill(latencyColor.opacity(0.75)).frame(width: geo.size.width * node.load) }
                }.frame(height: 3)
            }.padding(15).background(selected ? Theme.accent.opacity(0.085) : Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent.opacity(0.65) : Theme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Connections

struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var onlyActive = true
    var items: [ConnectionItem] { model.connections.filter { (!onlyActive || $0.status == .active) && (query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "连接", subtitle: "检查当前网络会话与流量") {
                HStack(spacing: 10) { PillButton(title: "关闭全部", icon: "xmark.circle", action: model.closeAllConnections); StatusBadge() }
            }
            HStack(spacing: 12) {
                MetricCard(label: "活动连接", value: "\(model.activeConnections.count)", detail: "+2 最近一分钟", icon: "bolt.horizontal.fill", tint: Theme.accent)
                MetricCard(label: "上传速率", value: String(format: "%.2f MB/s", model.uploadRate), detail: "峰值 5.21 MB/s", icon: "arrow.up", tint: Theme.accent2)
                MetricCard(label: "下载速率", value: String(format: "%.2f MB/s", model.downloadRate), detail: "峰值 18.4 MB/s", icon: "arrow.down", tint: Theme.warning)
            }.padding(.horizontal, 30).padding(.bottom, 16)
            VStack(spacing: 0) {
                HStack { SearchField(text: $query, placeholder: "搜索域名或应用").frame(width: 260); Toggle("仅活动", isOn: $onlyActive).toggleStyle(.switch).controlSize(.small).font(.system(size: 11)); Spacer(); Text("按下载流量排序").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(14)
                Divider().overlay(Theme.stroke)
                HStack { Text("应用 / 目标").frame(maxWidth: .infinity, alignment: .leading); Text("网络").frame(width: 70); Text("上传").frame(width: 78, alignment: .trailing); Text("下载").frame(width: 78, alignment: .trailing); Text("规则").frame(width: 150, alignment: .trailing) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 15).frame(height: 34)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack {
                                HStack(spacing: 10) { Image(systemName: item.symbol).frame(width: 28, height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 2) { Text(item.host).font(.system(size: 11, weight: .medium)); Text(item.app).font(.system(size: 9)).foregroundStyle(Theme.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.network).frame(width: 70); Text(item.upload).frame(width: 78, alignment: .trailing); Text(item.download).frame(width: 78, alignment: .trailing); Text(item.rule).foregroundStyle(Theme.accent).frame(width: 150, alignment: .trailing)
                            }.font(.system(size: 10)).padding(.horizontal, 15).frame(height: 52).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                        }
                    }
                }
            }.card(0).padding(.horizontal, 30).padding(.bottom, 26)
        }
    }
}

struct MetricCard: View {
    let label: String, value: String, detail: String, icon: String, tint: Color
    var body: some View {
        HStack(spacing: 13) { Image(systemName: icon).foregroundStyle(tint).frame(width: 38, height: 38).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary); Text(value).font(.system(size: 17, weight: .bold)); Text(detail).font(.system(size: 9)).foregroundStyle(Theme.secondary) }; Spacer() }.frame(maxWidth: .infinity).card(14)
    }
}

// MARK: - Rules

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "规则", subtitle: "查看规则集与命中策略") { PillButton(title: "更新规则集", icon: "arrow.clockwise", action: { model.showToast("规则集更新完成") }) }
            HStack { SearchField(text: $query, placeholder: "搜索规则").frame(width: 280); Spacer(); Text("共 18,426 条规则").font(.system(size: 11)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 30).padding(.bottom, 14)
            VStack(spacing: 0) {
                HStack { Text("类型").frame(width: 130, alignment: .leading); Text("匹配内容").frame(maxWidth: .infinity, alignment: .leading); Text("策略").frame(width: 140, alignment: .leading); Text("命中次数").frame(width: 90, alignment: .trailing) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).frame(height: 38).background(Color.black.opacity(0.12))
                ForEach(model.rules.filter { query.isEmpty || $0.payload.localizedCaseInsensitiveContains(query) }) { rule in
                    HStack { Text(rule.type).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.accent2).frame(width: 130, alignment: .leading); Text(rule.payload).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading); Text(rule.policy).font(.system(size: 10, weight: .medium)).foregroundStyle(rule.policy == "DIRECT" ? Theme.accent : Theme.warning).frame(width: 140, alignment: .leading); Text("\(rule.matches)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing) }.padding(.horizontal, 16).frame(height: 54).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                }
                Spacer()
            }.card(0).padding(.horizontal, 30).padding(.bottom, 26)
        }
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "配置", subtitle: "管理订阅与本地配置文件") {
                PillButton(title: "导入配置", icon: "plus", active: true) { model.showImportSheet = true }
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.activateProfile(profile)
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: profile.id == "default" ? "cloud.fill" : "doc.text.fill").font(.system(size: 18)).foregroundStyle(profile.id == model.activeProfileID ? Theme.accent : Theme.secondary).frame(width: 42, height: 42).background((profile.id == model.activeProfileID ? Theme.accent : Theme.secondary).opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 4) { HStack { Text(profile.name).font(.system(size: 14, weight: .bold)); if profile.id == model.activeProfileID { Text("使用中").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.black.opacity(0.75)).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent).clipShape(Capsule()) } }; Text(profile.source).font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                                Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(profile.updated).font(.system(size: 10, weight: .medium)); Text(profile.size).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                                Button { model.updateProfile(profile) } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).background(Theme.panelStrong).clipShape(Circle()) }.buttonStyle(.plain)
                                Button { } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }.buttonStyle(.plain)
                            }.padding(16).background(profile.id == model.activeProfileID ? Theme.accent.opacity(0.065) : Theme.panel).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(profile.id == model.activeProfileID ? Theme.accent.opacity(0.45) : Theme.stroke))
                        }.buttonStyle(.plain)
                    }
                    Button { model.showImportSheet = true } label: {
                        HStack { Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent); Text("添加订阅或本地配置").font(.system(size: 12, weight: .semibold)) }.frame(maxWidth: .infinity).frame(height: 70).background(Theme.panel.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 30)
                HStack(alignment: .top, spacing: 12) {
                    InfoTile(icon: "clock.arrow.circlepath", title: "自动更新", subtitle: "每 24 小时检查一次订阅更新")
                    InfoTile(icon: "checkmark.shield.fill", title: "配置检查", subtitle: "导入前验证语法与规则冲突")
                    InfoTile(icon: "externaldrive.fill", title: "自动备份", subtitle: "保留最近 5 个可用版本")
                }.padding(30)
            }
        }
    }
}

struct InfoTile: View {
    let icon: String, title: String, subtitle: String
    var body: some View { HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(Theme.accent2); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .semibold)); Text(subtitle).font(.system(size: 9)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer() }.frame(maxWidth: .infinity).card(14) }
}

struct ImportProfileSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { ZStack { RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.14)); Image(systemName: "link").foregroundStyle(Theme.accent) }.frame(width: 42, height: 42); VStack(alignment: .leading, spacing: 2) { Text("导入配置").font(.system(size: 18, weight: .bold)); Text("添加订阅链接或选择本地文件").font(.system(size: 11)).foregroundStyle(Theme.secondary) } }
            VStack(alignment: .leading, spacing: 7) {
                Text("订阅地址").font(.system(size: 11, weight: .semibold))
                TextField("https://example.com/subscription", text: $url)
                    .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 38)
                    .background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
                Text("支持 Clash / Mihomo 配置、Provider、Base64 与节点链接订阅")
                    .font(.system(size: 9)).foregroundStyle(Theme.secondary)
            }
            HStack { Rectangle().fill(Theme.stroke).frame(height: 1); Text("或者").font(.system(size: 10)).foregroundStyle(Theme.secondary); Rectangle().fill(Theme.stroke).frame(height: 1) }
            Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.importLocalProfile() } } label: { Label("选择本地文件", systemImage: "folder").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 42).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke)) }.buttonStyle(.plain)
            HStack { Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.secondary); Spacer(); Button("导入") { dismiss(); model.importProfile(from: url) }.buttonStyle(.plain).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.black.opacity(0.75)).padding(.horizontal, 20).frame(height: 36).background(Theme.accent).clipShape(Capsule()).disabled(url.isEmpty) }
        }.padding(24).frame(width: 470).background(Theme.bg)
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @State private var level = "全部"
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "日志", subtitle: "实时查看内核运行信息") {
                HStack(spacing: 10) { PillButton(title: "清空", icon: "trash") { model.logs.removeAll(); model.showToast("日志已清空") }; PillButton(title: "复制", icon: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logs.map { "\($0.time) [\($0.level)] \($0.message)" }.joined(separator: "\n"), forType: .string); model.showToast("日志已复制") } }
            }
            HStack { Picker("级别", selection: $level) { ForEach(["全部", "INFO", "WARN", "DEBUG"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 260); Spacer(); Label("自动滚动", systemImage: "arrow.down.to.line").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 30).padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.logs.filter { level == "全部" || $0.level == level }) { log in
                        HStack(alignment: .top, spacing: 12) { Text(log.time).foregroundStyle(Theme.secondary).frame(width: 60, alignment: .leading); Text(log.level).foregroundStyle(log.level == "WARN" ? Theme.warning : log.level == "DEBUG" ? Theme.accent2 : Theme.accent).frame(width: 50, alignment: .leading); Text(log.message).foregroundStyle(Theme.text.opacity(0.86)).textSelection(.enabled) }.font(.system(size: 10, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.08)).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                    }
                }
            }.card(0).padding(.horizontal, 30).padding(.bottom, 26)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = true
    @State private var autoUpdate = true
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: "调整 Aero 的运行方式") { StatusBadge() }
            ScrollView {
                VStack(spacing: 16) {
                    SettingsGroup(title: "通用") {
                        SettingToggle(icon: "power", title: "登录时启动", subtitle: "登录 macOS 后自动运行 Aero", isOn: $launchAtLogin)
                        SettingToggle(icon: "arrow.clockwise", title: "自动检查更新", subtitle: "自动下载并安装稳定版本", isOn: $autoUpdate)
                    }
                    SettingsGroup(title: "网络") {
                        HStack { VStack(alignment: .leading, spacing: 3) { Label("macOS 系统代理", systemImage: "network.badge.shield.half.filled").font(.system(size: 12, weight: .semibold)); Text("修改前自动备份，关闭或退出时恢复原设置").font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); Text(model.isConnected ? "已接管" : "未接管").font(.system(size: 10, weight: .semibold)).foregroundStyle(model.isConnected ? Theme.accent : Theme.secondary) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                        HStack { VStack(alignment: .leading, spacing: 3) { Label("代理端口", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .semibold)); Text("端口由当前 Mihomo 配置实时读取").font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); PortBadge(label: "HTTP", value: model.httpPort); PortBadge(label: "SOCKS", value: model.socksPort) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                        HStack { VStack(alignment: .leading, spacing: 3) { Label("TUN 模式", systemImage: "shield.lefthalf.filled").font(.system(size: 12, weight: .semibold)); Text("本构建使用系统 HTTP / HTTPS / SOCKS 代理，不修改路由表").font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); Text("未启用").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary) }.padding(.vertical, 12)
                    }
                    SettingsGroup(title: "内核") {
                        HStack { VStack(alignment: .leading, spacing: 3) { Label("Mihomo Core", systemImage: "cpu.fill").font(.system(size: 12, weight: .semibold)); Text(model.coreState.label + " · 控制器仅监听本机").font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); Text(model.coreVersion).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary); PillButton(title: "重启内核", icon: "arrow.clockwise") { Task { await model.startCore() } } }.padding(.vertical, 12)
                    }
                    Text("Aero 1.1.2 (Build 122) · Made for macOS").font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.top, 4)
                }.padding(.horizontal, 30).padding(.bottom, 30)
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary).padding(.horizontal, 4).padding(.bottom, 8); VStack(spacing: 0) { content() }.padding(.horizontal, 15).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke)) } }
}

struct SettingToggle: View {
    let icon: String, title: String, subtitle: String
    @Binding var isOn: Bool
    var body: some View { HStack { VStack(alignment: .leading, spacing: 3) { Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)); Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) } }
}

struct LabeledPort: View {
    let label: String
    @Binding var value: String
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondary); TextField("", text: $value).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).frame(width: 74, height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke)) } }
}

struct PortBadge: View {
    let label: String
    let value: Int
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondary); Text("\(value)").font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).frame(height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke)) } }
}

// MARK: - Command palette & menu bar

struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    let commands: [(String, String, SidebarSection?)] = [
        ("切换系统代理", "power", nil), ("打开代理节点", "point.3.connected.trianglepath.dotted", .proxies), ("查看活动连接", "arrow.triangle.branch", .connections), ("导入新配置", "plus", .profiles), ("打开设置", "gearshape", .settings)
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture { model.showCommandPalette = false }
            VStack(spacing: 0) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary); TextField("输入命令…", text: $query).textFieldStyle(.plain).font(.system(size: 15)); Text("esc").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 4)) }.padding(.horizontal, 16).frame(height: 52)
                Divider().overlay(Theme.stroke)
                VStack(spacing: 3) {
                    ForEach(Array(commands.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }.enumerated()), id: \.offset) { _, cmd in
                        Button { if let section = cmd.2 { model.selectedSection = section }; if cmd.0 == "切换系统代理" { model.toggleConnection() }; if cmd.0 == "导入新配置" { model.showImportSheet = true }; model.showCommandPalette = false } label: { HStack(spacing: 11) { Image(systemName: cmd.1).frame(width: 22).foregroundStyle(Theme.accent); Text(cmd.0).font(.system(size: 12, weight: .medium)); Spacer(); Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.padding(8)
            }.frame(width: 440).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.stroke)).shadow(color: .black.opacity(0.45), radius: 35, y: 15).offset(y: -100)
        }.onExitCommand { model.showCommandPalette = false }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { ZStack { RoundedRectangle(cornerRadius: 8).fill(Theme.accent); Image(systemName: "wind").foregroundStyle(Color.black.opacity(0.7)) }.frame(width: 32, height: 32); VStack(alignment: .leading, spacing: 1) { Text("Aero").font(.system(size: 14, weight: .bold)); Text(model.isConnected ? "系统代理已开启" : "系统代理已关闭").font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer() }
            ModePicker(selection: model.modeBinding)
            HStack { Text(model.selectedNode.countryCode); VStack(alignment: .leading, spacing: 1) { Text(model.selectedNode.name).font(.system(size: 11, weight: .semibold)); Text("\(model.selectedNode.latency) ms").font(.system(size: 9)).foregroundStyle(Theme.secondary) }; Spacer(); Text(String(format: "↓ %.1f MB/s", model.downloadRate)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.accent) }.padding(10).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            Button { model.toggleConnection() } label: { Label(model.isConnected ? "关闭系统代理" : "开启系统代理", systemImage: "power").font(.system(size: 11, weight: .bold)).frame(maxWidth: .infinity).frame(height: 34).background(model.isConnected ? Theme.panelStrong : Theme.accent).foregroundStyle(model.isConnected ? Theme.text : Color.black.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
        }.padding(14).frame(width: 270).background(Theme.bg)
    }
}
