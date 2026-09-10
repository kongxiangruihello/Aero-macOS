import Foundation

enum AdvancedTestFailure: Error {
    case failed(String)
}

@main
struct AdvancedSettingsTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw AdvancedTestFailure.failed("usage: tests <mihomo> <workdir>") }
        let coreURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let workDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let base = """
        mixed-port: 7890
        allow-lan: false
        mode: rule
        proxies: []
        proxy-groups:
          - name: 节点选择
            type: select
            proxies: [DIRECT]
        rules:
          - MATCH,DIRECT
        """
        var settings = RuntimeSettings.standard
        settings.allowLAN = true
        settings.useMixedPort = false
        settings.httpPort = 18_080
        settings.socksPort = 18_081
        settings.dnsOverrideEnabled = true
        settings.dnsMode = .fakeIP
        settings.snifferEnabled = true
        settings.customRules = "PROCESS-NAME,curl,DIRECT\nDOMAIN-SUFFIX,example.com,节点选择"
        settings.ruleProvider = RuleProviderOverride(enabled: true, name: "RemoteRules", url: "https://example.com/rules.yaml", behavior: "classical", intervalSeconds: 3600, policy: "节点选择")

        let rendered = try RuntimeConfigOverlay.render(baseData: Data(base.utf8), settings: settings, tunEnabled: false)
        let text = String(decoding: rendered, as: UTF8.self)
        for expected in ["allow-lan: true", "port: 18080", "socks-port: 18081", "proxy-server-nameserver:", "override-destination:", "PROCESS-NAME,curl,DIRECT", "RULE-SET,RemoteRules,节点选择"] where !text.contains(expected) {
            throw AdvancedTestFailure.failed("missing overlay: \(expected)")
        }
        guard !base.contains("PROCESS-NAME") else { throw AdvancedTestFailure.failed("base configuration was changed") }

        let configURL = workDirectory.appendingPathComponent("advanced.yaml")
        try rendered.write(to: configURL, options: .atomic)
        try validate(coreURL: coreURL, configURL: configURL, dataDirectory: workDirectory)

        let inlineBase = """
        mixed-port: 7890
        proxies: []
        proxy-groups:
          - name: 节点选择
            type: select
            proxies: [DIRECT]
        rule-providers: {}
        rules: [MATCH,DIRECT]
        """
        let renderedInline = try RuntimeConfigOverlay.render(baseData: Data(inlineBase.utf8), settings: settings, tunEnabled: false)
        let inlineURL = workDirectory.appendingPathComponent("advanced-inline.yaml")
        try renderedInline.write(to: inlineURL, options: .atomic)
        try validate(coreURL: coreURL, configURL: inlineURL, dataDirectory: workDirectory)

        let jsonBase: [String: Any] = [
            "mixed-port": 7890,
            "proxies": [],
            "proxy-groups": [["name": "节点选择", "type": "select", "proxies": ["DIRECT"]]],
            "rules": ["MATCH,DIRECT"]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonBase)
        let renderedJSON = try RuntimeConfigOverlay.render(baseData: jsonData, settings: settings, tunEnabled: false)
        guard let object = try JSONSerialization.jsonObject(with: renderedJSON) as? [String: Any],
              (object["port"] as? NSNumber)?.intValue == 18_080,
              object["dns"] != nil,
              object["sniffer"] != nil else {
            throw AdvancedTestFailure.failed("JSON overlay failed")
        }

        let webDAVStore = WebDAVSettingsStore(root: workDirectory)
        let webDAV = WebDAVSettings(serverURL: "https://dav.example.com/", username: "aero", remotePath: "backup.json")
        try webDAVStore.save(webDAV)
        guard webDAVStore.load() == webDAV else { throw AdvancedTestFailure.failed("WebDAV settings persistence failed") }

        let historyStore = TrafficHistoryStore(root: workDirectory)
        _ = try historyStore.record(uploadBytes: 100, downloadBytes: 200)
        let history = try historyStore.record(uploadBytes: 50, downloadBytes: 75)
        guard let today = history.last, today.uploadBytes >= 150, today.downloadBytes >= 275 else {
            throw AdvancedTestFailure.failed("traffic history persistence failed")
        }
        print("PASS advanced settings overlay and Mihomo validation")
    }

    private static func validate(coreURL: URL, configURL: URL, dataDirectory: URL) throws {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = coreURL
        task.arguments = ["-t", "-d", dataDirectory.path, "-f", configURL.path, "-ext-ctl", "127.0.0.1:0"]
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "validation failed"
            throw AdvancedTestFailure.failed(output)
        }
    }
}
