import Foundation

enum ProxyCaptureMode: String, Codable, CaseIterable, Identifiable {
    case system = "系统代理"
    case pac = "PAC"
    case tun = "TUN"

    var id: String { rawValue }
}

enum DNSMode: String, Codable, CaseIterable, Identifiable {
    case fakeIP = "Fake-IP"
    case redirHost = "Redir-Host"

    var id: String { rawValue }
    var configValue: String { self == .fakeIP ? "fake-ip" : "redir-host" }
}

enum TUNStack: String, Codable, CaseIterable, Identifiable {
    case mixed = "mixed"
    case system = "system"
    case gvisor = "gVisor"

    var id: String { rawValue }
    var configValue: String { self == .gvisor ? "gvisor" : rawValue }
}

enum CoreChannel: String, Codable, CaseIterable, Identifiable {
    case stable = "稳定版"
    case preview = "预览版"

    var id: String { rawValue }
    var resourceName: String { self == .stable ? "mihomo" : "mihomo-preview" }
}

struct SubscriptionPreference: Codable, Equatable {
    var updateIntervalHours = 24
    var userAgent = ""
    var lastUpdated: Date?
}

struct SubscriptionUsage: Codable, Equatable {
    var usedBytes: Int64
    var totalBytes: Int64
    var expiresAt: Date?

    var summary: String {
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .decimal)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal)
        return totalBytes > 0 ? "已用 \(used) / \(total)" : "已用 \(used)"
    }

    var expiryText: String? {
        guard let expiresAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "到期 \(formatter.string(from: expiresAt))"
    }
}

struct RuleProviderOverride: Codable, Equatable {
    var enabled = false
    var name = "KongRules"
    var url = ""
    var behavior = "classical"
    var intervalSeconds = 86_400
    var policy = "节点选择"
}

struct WebDAVSettings: Codable, Equatable {
    var serverURL = ""
    var username = ""
    var remotePath = "Kong-backup.json"
}

struct WebDAVSettingsStore: Sendable {
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("webdav-settings.json")
    }

    func load() -> WebDAVSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(WebDAVSettings.self, from: data) else {
            return WebDAVSettings()
        }
        return settings
    }

    func save(_ settings: WebDAVSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct DailyTraffic: Codable, Equatable, Identifiable {
    var id: String { day }
    let day: String
    var uploadBytes: Int64
    var downloadBytes: Int64
}

struct TrafficHistoryStore: Sendable {
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("traffic-history.json")
    }

    func load() -> [DailyTraffic] {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([DailyTraffic].self, from: data) else { return [] }
        return history.sorted { $0.day < $1.day }
    }

    func record(uploadBytes: Int64, downloadBytes: Int64) throws -> [DailyTraffic] {
        var history = load()
        let day = Self.dayKey(Date())
        if let index = history.firstIndex(where: { $0.day == day }) {
            history[index].uploadBytes += max(0, uploadBytes)
            history[index].downloadBytes += max(0, downloadBytes)
        } else {
            history.append(DailyTraffic(day: day, uploadBytes: max(0, uploadBytes), downloadBytes: max(0, downloadBytes)))
        }
        history = Array(history.sorted { $0.day < $1.day }.suffix(90))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return history
    }

    static func dayKey(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct RuntimeSettings: Codable, Equatable {
    var captureMode: ProxyCaptureMode = .system
    var coreChannel: CoreChannel = .stable
    var allowLAN = false
    var useMixedPort = true
    var mixedPort = 17_890
    var httpPort = 17_890
    var socksPort = 17_891

    var dnsOverrideEnabled = false
    var dnsMode: DNSMode = .fakeIP
    var dnsListen = "127.0.0.1:1053"
    var nameservers = "https://1.12.12.12/dns-query\nhttps://223.5.5.5/dns-query"
    var fallbackNameservers = "https://1.1.1.1/dns-query\ntls://8.8.8.8"
    var proxyServerNameservers = "https://223.5.5.5/dns-query\nhttps://1.12.12.12/dns-query"
    var preferH3 = false
    var respectRules = false

    var snifferEnabled = true
    var overrideDestination = true
    var tunAutoRoute = true
    var tunAutoDetectInterface = true
    var tunDNSHijack = true
    var tunStack: TUNStack = .mixed

    var customRules = ""
    var ruleProvider = RuleProviderOverride()
    var automaticSubscriptionUpdates = true
    var subscriptionPreferences: [String: SubscriptionPreference] = [:]
    var subscriptionUsage: [String: SubscriptionUsage] = [:]

    static let standard = RuntimeSettings()
}

struct RuntimeSettingsStore: Sendable {
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("runtime-settings.json")
    }

    func load() -> RuntimeSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(RuntimeSettings.self, from: data) else {
            return .standard
        }
        return settings
    }

    func save(_ settings: RuntimeSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum RuntimeConfigOverlayError: LocalizedError {
    case unreadableConfiguration

    var errorDescription: String? { "配置文件不是有效的 UTF-8 或 JSON" }
}

enum RuntimeConfigOverlay {
    static func render(baseData: Data, settings: RuntimeSettings, tunEnabled: Bool) throws -> Data {
        if let object = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] {
            return try renderJSON(object, settings: settings, tunEnabled: tunEnabled)
        }
        guard let text = String(data: baseData, encoding: .utf8) else {
            throw RuntimeConfigOverlayError.unreadableConfiguration
        }
        return Data(renderYAML(text, settings: settings, tunEnabled: tunEnabled).utf8)
    }

    private static func renderJSON(_ original: [String: Any], settings: RuntimeSettings, tunEnabled: Bool) throws -> Data {
        var object = original
        applyPorts(to: &object, settings: settings)
        object["allow-lan"] = settings.allowLAN
        object["bind-address"] = settings.allowLAN ? "*" : "127.0.0.1"
        object["tun"] = tunObject(settings, enabled: tunEnabled)
        object["sniffer"] = snifferObject(settings)
        if settings.dnsOverrideEnabled { object["dns"] = dnsObject(settings) }

        let customRules = normalizedRules(settings.customRules)
        if !customRules.isEmpty {
            object["rules"] = customRules + (object["rules"] as? [Any] ?? [])
        }
        if settings.ruleProvider.enabled, let provider = providerObject(settings.ruleProvider) {
            var providers = object["rule-providers"] as? [String: Any] ?? [:]
            providers[settings.ruleProvider.name] = provider
            object["rule-providers"] = providers
            let rule = "RULE-SET,\(settings.ruleProvider.name),\(settings.ruleProvider.policy)"
            object["rules"] = [rule] + (object["rules"] as? [Any] ?? [])
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func renderYAML(_ original: String, settings: RuntimeSettings, tunEnabled: Bool) -> String {
        var text = original
        let ports: [(String, String)] = settings.useMixedPort
            ? [("mixed-port", "\(settings.mixedPort)"), ("port", "0"), ("socks-port", "0")]
            : [("mixed-port", "0"), ("port", "\(settings.httpPort)"), ("socks-port", "\(settings.socksPort)")]
        for (key, value) in ports { text = replacingTopLevelScalar(key, value: value, in: text) }
        text = replacingTopLevelScalar("allow-lan", value: settings.allowLAN ? "true" : "false", in: text)
        text = replacingTopLevelScalar("bind-address", value: settings.allowLAN ? "\"*\"" : "127.0.0.1", in: text)
        text = replacingTopLevelBlock("tun", block: tunYAML(settings, enabled: tunEnabled), in: text)
        text = replacingTopLevelBlock("sniffer", block: snifferYAML(settings), in: text)
        if settings.dnsOverrideEnabled {
            text = replacingTopLevelBlock("dns", block: dnsYAML(settings), in: text)
        }

        var rules = normalizedRules(settings.customRules)
        if settings.ruleProvider.enabled, providerObject(settings.ruleProvider) != nil {
            text = mergingRuleProvider(settings.ruleProvider, in: text)
            rules.insert("RULE-SET,\(settings.ruleProvider.name),\(settings.ruleProvider.policy)", at: 0)
        }
        if !rules.isEmpty { text = prependingRules(rules, in: text) }
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func applyPorts(to object: inout [String: Any], settings: RuntimeSettings) {
        object["mixed-port"] = settings.useMixedPort ? settings.mixedPort : 0
        object["port"] = settings.useMixedPort ? 0 : settings.httpPort
        object["socks-port"] = settings.useMixedPort ? 0 : settings.socksPort
    }

    private static func dnsObject(_ settings: RuntimeSettings) -> [String: Any] {
        return [
            "enable": true,
            "listen": settings.dnsListen,
            "enhanced-mode": settings.dnsMode.configValue,
            "fake-ip-range": "198.18.0.1/16",
            "prefer-h3": settings.preferH3,
            "respect-rules": settings.respectRules,
            "nameserver": lines(settings.nameservers),
            "fallback": lines(settings.fallbackNameservers),
            "fallback-filter": ["geoip": false],
            "proxy-server-nameserver": lines(settings.proxyServerNameservers)
        ]
    }

    private static func snifferObject(_ settings: RuntimeSettings) -> [String: Any] {
        [
            "enable": settings.snifferEnabled,
            "force-dns-mapping": true,
            "parse-pure-ip": true,
            "override-destination": settings.overrideDestination,
            "sniff": [
                "HTTP": ["ports": [80, "8080-8880"], "override-destination": settings.overrideDestination],
                "TLS": ["ports": [443, 8443]],
                "QUIC": ["ports": [443, 8443]]
            ]
        ]
    }

    private static func tunObject(_ settings: RuntimeSettings, enabled: Bool) -> [String: Any] {
        [
            "enable": enabled,
            "stack": settings.tunStack.configValue,
            "auto-route": settings.tunAutoRoute,
            "auto-detect-interface": settings.tunAutoDetectInterface,
            "dns-hijack": settings.tunDNSHijack ? ["any:53", "tcp://any:53"] : []
        ]
    }

    private static func providerObject(_ provider: RuleProviderOverride) -> [String: Any]? {
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let url = URL(string: provider.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["classical", "domain", "ipcidr"].contains(provider.behavior) else { return nil }
        return [
            "type": "http",
            "url": url.absoluteString,
            "path": "./Providers/rules-\(safeName(name)).yaml",
            "interval": max(300, provider.intervalSeconds),
            "behavior": provider.behavior,
            "format": "yaml"
        ]
    }

    private static func dnsYAML(_ settings: RuntimeSettings) -> String {
        var rows = [
            "dns:",
            "  enable: true",
            "  listen: \(yamlString(settings.dnsListen))",
            "  enhanced-mode: \(settings.dnsMode.configValue)",
            "  fake-ip-range: 198.18.0.1/16",
            "  prefer-h3: \(settings.preferH3)",
            "  respect-rules: \(settings.respectRules)"
        ]
        rows += yamlList("nameserver", values: lines(settings.nameservers), indent: 2)
        rows += yamlList("fallback", values: lines(settings.fallbackNameservers), indent: 2)
        rows += ["  fallback-filter:", "    geoip: false"]
        rows += yamlList("proxy-server-nameserver", values: lines(settings.proxyServerNameservers), indent: 2)
        return rows.joined(separator: "\n")
    }

    private static func snifferYAML(_ settings: RuntimeSettings) -> String {
        [
            "sniffer:",
            "  enable: \(settings.snifferEnabled)",
            "  force-dns-mapping: true",
            "  parse-pure-ip: true",
            "  override-destination: \(settings.overrideDestination)",
            "  sniff:",
            "    HTTP:",
            "      ports: [80, 8080-8880]",
            "      override-destination: \(settings.overrideDestination)",
            "    TLS:",
            "      ports: [443, 8443]",
            "    QUIC:",
            "      ports: [443, 8443]"
        ].joined(separator: "\n")
    }

    private static func tunYAML(_ settings: RuntimeSettings, enabled: Bool) -> String {
        let dnsHijack = settings.tunDNSHijack ? "['any:53', 'tcp://any:53']" : "[]"
        return [
            "tun:",
            "  enable: \(enabled)",
            "  stack: \(settings.tunStack.configValue)",
            "  auto-route: \(settings.tunAutoRoute)",
            "  auto-detect-interface: \(settings.tunAutoDetectInterface)",
            "  dns-hijack: \(dnsHijack)"
        ].joined(separator: "\n")
    }

    private static func mergingRuleProvider(_ provider: RuleProviderOverride, in text: String) -> String {
        guard providerObject(provider) != nil else { return text }
        let entry = [
            "  \(yamlString(provider.name)):",
            "    type: http",
            "    url: \(yamlString(provider.url))",
            "    path: ./Providers/rules-\(safeName(provider.name)).yaml",
            "    interval: \(max(300, provider.intervalSeconds))",
            "    behavior: \(provider.behavior)",
            "    format: yaml"
        ].joined(separator: "\n")
        let lines = text.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { isTopLevelKey("rule-providers", line: $0) }) {
            var result = lines
            let inlineValue = String(result[index].drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
            if inlineValue == "{}" || inlineValue == "null" { result[index] = "rule-providers:" }
            result.insert(entry, at: index + 1)
            return result.joined(separator: "\n")
        }
        return text + (text.hasSuffix("\n") ? "" : "\n") + "rule-providers:\n\(entry)\n"
    }

    private static func prependingRules(_ rules: [String], in text: String) -> String {
        let entries = rules.map { "  - \($0)" }
        var lines = text.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { isTopLevelKey("rules", line: $0) }) {
            let inlineValue = String(lines[index].drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces)
            if inlineValue.isEmpty {
                lines.insert(contentsOf: entries, at: index + 1)
            } else {
                lines[index] = "rules:"
                var preserved = inlineValue
                if preserved == "[]" { preserved = "" }
                if preserved.hasPrefix("["), preserved.hasSuffix("]") {
                    preserved = String(preserved.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                }
                lines.insert(contentsOf: entries + (preserved.isEmpty ? [] : ["  - \(preserved)"]), at: index + 1)
            }
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("rules:")
            lines.append(contentsOf: entries)
        }
        return lines.joined(separator: "\n")
    }

    private static func replacingTopLevelScalar(_ key: String, value: String, in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { isTopLevelKey(key, line: $0) }) {
            lines[index] = "\(key): \(value)"
        } else {
            lines.insert("\(key): \(value)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func replacingTopLevelBlock(_ key: String, block: String, in text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { isTopLevelKey(key, line: $0) }) {
            var end = start + 1
            while end < lines.count {
                let line = lines[end]
                if !line.trimmingCharacters(in: .whitespaces).isEmpty,
                   !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                   line.first?.isWhitespace != true { break }
                end += 1
            }
            lines.replaceSubrange(start..<end, with: block.components(separatedBy: .newlines))
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: block.components(separatedBy: .newlines))
        }
        return lines.joined(separator: "\n")
    }

    private static func isTopLevelKey(_ key: String, line: String) -> Bool {
        guard line.first?.isWhitespace != true else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("#") && trimmed.hasPrefix("\(key):")
    }

    private static func normalizedRules(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("-") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return line.isEmpty ? nil : line
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func yamlList(_ key: String, values: [String], indent: Int) -> [String] {
        let prefix = String(repeating: " ", count: indent)
        return ["\(prefix)\(key):"] + values.map { "\(prefix)  - \(yamlString($0))" }
    }

    private static func yamlString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}
