import Foundation

struct PreparedSubscription {
    let configData: Data
    let providerData: Data?
    let providerFileName: String?
    let label: String
    let nodeCount: Int?
}

enum SubscriptionFormatError: LocalizedError {
    case empty
    case unsupported
    case noValidNodes(Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "订阅返回了空内容"
        case .unsupported: return "无法识别订阅格式。请确认链接返回 Clash/Mihomo YAML、Provider YAML、Base64 或节点 URI 列表"
        case .noValidNodes(let count): return "识别到节点列表，但其中 \(count) 条均无法转换为 Mihomo 配置"
        }
    }
}

enum SubscriptionFormatter {
    private static let supportedSchemes = ["ss://", "ssr://", "trojan://", "vless://", "vmess://", "hysteria2://", "hy2://", "tuic://"]

    static func prepare(data: Data, id: String) throws -> PreparedSubscription {
        guard !data.isEmpty else { throw SubscriptionFormatError.empty }
        let text = decodeText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SubscriptionFormatError.empty }

        if looksLikeFullConfig(text) {
            return PreparedSubscription(configData: Data(text.utf8), providerData: nil, providerFileName: nil, label: "Clash/Mihomo 配置", nodeCount: nil)
        }

        if looksLikeProvider(text) {
            let fileName = "\(id).yaml"
            return PreparedSubscription(configData: try providerWrapper(providerFileName: fileName), providerData: Data(text.utf8), providerFileName: fileName, label: "代理提供者订阅", nodeCount: estimateYAMLNodeCount(text))
        }

        let decoded = decodeBase64Text(text) ?? text
        let uriLines = decoded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in supportedSchemes.contains(where: { line.lowercased().hasPrefix($0) }) }
        if !uriLines.isEmpty {
            let proxies = uriLines.compactMap(parseProxyURI)
            guard !proxies.isEmpty else { throw SubscriptionFormatError.noValidNodes(uriLines.count) }
            return PreparedSubscription(configData: try generatedConfig(proxies: proxies), providerData: nil, providerFileName: nil, label: "节点链接订阅", nodeCount: proxies.count)
        }

        throw SubscriptionFormatError.unsupported
    }

    private static func decodeText(_ data: Data) -> String {
        if var value = String(data: data, encoding: .utf8) {
            if value.hasPrefix("\u{feff}") { value.removeFirst() }
            return value
        }
        if let value = String(data: data, encoding: .utf16) { return value }
        return ""
    }

    private static func looksLikeFullConfig(_ text: String) -> Bool {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object["proxy-groups"] != nil || object["rules"] != nil || object["proxy-providers"] != nil
        }
        return containsTopLevelKey("proxy-groups", in: text) || containsTopLevelKey("rules", in: text) || containsTopLevelKey("proxy-providers", in: text)
    }

    private static func looksLikeProvider(_ text: String) -> Bool {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object["proxies"] != nil
        }
        return containsTopLevelKey("proxies", in: text)
    }

    private static func containsTopLevelKey(_ key: String, in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.first?.isWhitespace != true, !trimmed.hasPrefix("#") else { return false }
            return trimmed.hasPrefix("\(key):")
        }
    }

    private static func providerWrapper(providerFileName: String) throws -> Data {
        let object: [String: Any] = [
            "mixed-port": 0,
            "allow-lan": false,
            "bind-address": "127.0.0.1",
            "mode": "rule",
            "log-level": "info",
            "ipv6": false,
            "proxy-providers": [
                "Aero Subscription": [
                    "type": "file",
                    "path": "./Providers/\(providerFileName)",
                    "health-check": ["enable": true, "url": "https://www.gstatic.com/generate_204", "interval": 600]
                ]
            ],
            "proxy-groups": [["name": "节点选择", "type": "select", "use": ["Aero Subscription"]]],
            "rules": ["MATCH,节点选择"]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func generatedConfig(proxies: [[String: Any]]) throws -> Data {
        let names = proxies.compactMap { $0["name"] as? String }
        let object: [String: Any] = [
            "mixed-port": 0,
            "allow-lan": false,
            "bind-address": "127.0.0.1",
            "mode": "rule",
            "log-level": "info",
            "ipv6": false,
            "proxies": proxies,
            "proxy-groups": [["name": "节点选择", "type": "select", "proxies": names]],
            "rules": ["MATCH,节点选择"]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func decodeBase64Text(_ text: String) -> String? {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.count > 24, compact.allSatisfy({ $0.isLetter || $0.isNumber || "+/_-=".contains($0) }) else { return nil }
        var standard = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - standard.count % 4) % 4
        standard += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: standard, options: .ignoreUnknownCharacters),
              let value = String(data: data, encoding: .utf8),
              supportedSchemes.contains(where: { value.lowercased().contains($0) }) else { return nil }
        return value
    }

    private static func decodeBase64(_ value: String) -> String? {
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseProxyURI(_ rawLine: String) -> [String: Any]? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = line.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
        switch scheme {
        case "ss": return parseShadowsocks(line)
        case "ssr": return parseShadowsocksR(line)
        case "trojan": return parseTrojan(line)
        case "vless": return parseVLESS(line)
        case "vmess": return parseVMess(line)
        case "hysteria2", "hy2": return parseHysteria2(line)
        case "tuic": return parseTUIC(line)
        default: return nil
        }
    }

    private static func parseVLESS(_ value: String) -> [String: Any]? {
        guard let components = URLComponents(string: value), let host = components.host, let port = components.port, let uuid = components.user, !uuid.isEmpty else { return nil }
        let query = queryMap(components)
        var proxy: [String: Any] = baseProxy(type: "vless", components: components, server: host, port: port)
        proxy["uuid"] = uuid
        proxy["udp"] = true
        if let flow = query["flow"], !flow.isEmpty { proxy["flow"] = flow }
        let security = query["security"]?.lowercased()
        if security == "tls" || security == "reality" {
            proxy["tls"] = true
            proxy["servername"] = query["sni"] ?? host
            proxy["client-fingerprint"] = query["fp"] ?? "chrome"
            if security == "reality", let publicKey = nonEmpty(query["pbk"]) {
                var reality: [String: String] = ["public-key": publicKey]
                if let shortID = nonEmpty(query["sid"]) { reality["short-id"] = shortID }
                proxy["reality-opts"] = reality
            }
        }
        applyTransport(query: query, to: &proxy)
        return proxy
    }

    private static func parseTrojan(_ value: String) -> [String: Any]? {
        guard let components = URLComponents(string: value), let host = components.host, let port = components.port, let password = components.user, !password.isEmpty else { return nil }
        let query = queryMap(components)
        var proxy: [String: Any] = baseProxy(type: "trojan", components: components, server: host, port: port)
        proxy["password"] = password
        proxy["udp"] = true
        proxy["sni"] = query["sni"] ?? host
        proxy["skip-cert-verify"] = boolValue(query["allowInsecure"] ?? query["insecure"])
        applyTransport(query: query, to: &proxy)
        return proxy
    }

    private static func parseHysteria2(_ value: String) -> [String: Any]? {
        guard let components = URLComponents(string: value), let host = components.host, let port = components.port, let password = components.user, !password.isEmpty else { return nil }
        let query = queryMap(components)
        var proxy: [String: Any] = baseProxy(type: "hysteria2", components: components, server: host, port: port)
        proxy["password"] = password
        proxy["sni"] = query["sni"] ?? host
        proxy["skip-cert-verify"] = boolValue(query["insecure"])
        if let obfs = query["obfs"], !obfs.isEmpty {
            proxy["obfs"] = obfs
            proxy["obfs-password"] = query["obfs-password"] ?? query["obfsPassword"] ?? ""
        }
        return proxy
    }

    private static func parseTUIC(_ value: String) -> [String: Any]? {
        guard let components = URLComponents(string: value), let host = components.host, let port = components.port, let uuid = components.user, let password = components.password else { return nil }
        let query = queryMap(components)
        var proxy: [String: Any] = baseProxy(type: "tuic", components: components, server: host, port: port)
        proxy["uuid"] = uuid
        proxy["password"] = password
        proxy["sni"] = query["sni"] ?? host
        proxy["skip-cert-verify"] = boolValue(query["allow_insecure"] ?? query["insecure"])
        proxy["congestion-controller"] = query["congestion_control"] ?? "bbr"
        proxy["udp-relay-mode"] = query["udp_relay_mode"] ?? "native"
        return proxy
    }

    private static func parseVMess(_ value: String) -> [String: Any]? {
        let payload = String(value.dropFirst("vmess://".count))
        guard let decoded = decodeBase64(payload), let data = decoded.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let host = string(json["add"]), let port = int(json["port"]), let uuid = string(json["id"]) else { return nil }
        var proxy: [String: Any] = [
            "name": nonEmpty(string(json["ps"])) ?? "VMess \(host):\(port)",
            "type": "vmess",
            "server": host,
            "port": port,
            "uuid": uuid,
            "alterId": int(json["aid"]) ?? 0,
            "cipher": nonEmpty(string(json["scy"])) ?? "auto",
            "udp": true
        ]
        let network = nonEmpty(string(json["net"])) ?? "tcp"
        proxy["network"] = network
        if string(json["tls"])?.lowercased() == "tls" {
            proxy["tls"] = true
            proxy["servername"] = nonEmpty(string(json["sni"])) ?? host
        }
        if network == "ws" {
            var headers: [String: String] = [:]
            if let wsHost = nonEmpty(string(json["host"])) { headers["Host"] = wsHost }
            proxy["ws-opts"] = ["path": nonEmpty(string(json["path"])) ?? "/", "headers": headers]
        }
        return proxy
    }

    private static func parseShadowsocks(_ value: String) -> [String: Any]? {
        var body = String(value.dropFirst("ss://".count))
        let fragment: String?
        if let hash = body.firstIndex(of: "#") {
            fragment = String(body[body.index(after: hash)...]).removingPercentEncoding
            body = String(body[..<hash])
        } else { fragment = nil }
        if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }

        var decodedAuthority = body
        if !body.contains("@"), let decoded = decodeBase64(body) { decodedAuthority = decoded }
        guard let at = decodedAuthority.lastIndex(of: "@") else { return nil }
        var credentials = String(decodedAuthority[..<at])
        let endpoint = String(decodedAuthority[decodedAuthority.index(after: at)...])
        if !credentials.contains(":"), let decoded = decodeBase64(credentials) { credentials = decoded }
        guard let colon = credentials.firstIndex(of: ":") else { return nil }
        let method = String(credentials[..<colon])
        let password = String(credentials[credentials.index(after: colon)...])
        guard let endpointURL = URLComponents(string: "ss://\(endpoint)"), let host = endpointURL.host, let port = endpointURL.port else { return nil }
        return ["name": nonEmpty(fragment) ?? "SS \(host):\(port)", "type": "ss", "server": host, "port": port, "cipher": method, "password": password, "udp": true]
    }

    private static func parseShadowsocksR(_ value: String) -> [String: Any]? {
        let payload = String(value.dropFirst("ssr://".count))
        guard let decoded = decodeBase64(payload) else { return nil }
        let sections = decoded.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let authority = String(sections[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fields = authority.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, let port = Int(fields[1]), let password = decodeBase64(fields[5]) else { return nil }
        let queryText = sections.count > 1 ? String(sections[1]) : ""
        let query = URLComponents(string: "https://aero.invalid/?\(queryText)").map(queryMap) ?? [:]
        let remarks = query["remarks"].flatMap(decodeBase64).flatMap(nonEmpty)
        var proxy: [String: Any] = [
            "name": remarks ?? "SSR \(fields[0]):\(port)",
            "type": "ssr",
            "server": fields[0],
            "port": port,
            "protocol": fields[2],
            "cipher": fields[3],
            "obfs": fields[4],
            "password": password,
            "udp": true
        ]
        if let parameter = query["protoparam"].flatMap(decodeBase64).flatMap(nonEmpty) { proxy["protocol-param"] = parameter }
        if let parameter = query["obfsparam"].flatMap(decodeBase64).flatMap(nonEmpty) { proxy["obfs-param"] = parameter }
        return proxy
    }

    private static func baseProxy(type: String, components: URLComponents, server: String, port: Int) -> [String: Any] {
        let name = components.fragment?.removingPercentEncoding.flatMap(nonEmpty) ?? "\(type.uppercased()) \(server):\(port)"
        return ["name": name, "type": type, "server": server, "port": port]
    }

    private static func applyTransport(query: [String: String], to proxy: inout [String: Any]) {
        let network = query["type"]?.lowercased() ?? "tcp"
        proxy["network"] = network
        if network == "ws" {
            var headers: [String: String] = [:]
            if let host = nonEmpty(query["host"]) { headers["Host"] = host }
            proxy["ws-opts"] = ["path": query["path"]?.removingPercentEncoding ?? "/", "headers": headers]
        } else if network == "grpc" {
            proxy["grpc-opts"] = ["grpc-service-name": query["serviceName"] ?? query["service-name"] ?? ""]
        }
    }

    private static func queryMap(_ components: URLComponents) -> [String: String] {
        (components.queryItems ?? []).reduce(into: [:]) { result, item in
            if result[item.name] == nil { result[item.name] = item.value ?? "" }
        }
    }

    private static func boolValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func estimateYAMLNodeCount(_ text: String) -> Int? {
        let count = text.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- name:") }.count
        return count > 0 ? count : nil
    }
}
