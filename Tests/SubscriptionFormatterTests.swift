import Foundation

final class FallbackURLProtocol: URLProtocol {
    static var observedUserAgents: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        Self.observedUserAgents.append(userAgent)
        let succeeds = Self.observedUserAgents.count == SubscriptionDownloader.clientUserAgents.count
        let status = succeeds ? 200 : 403
        let body = succeeds ? """
        mixed-port: 0
        mode: rule
        proxies: []
        proxy-groups:
          - name: 节点选择
            type: select
            proxies: [DIRECT]
        rules: [MATCH,DIRECT]
        """ : "Forbidden"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/yaml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
struct SubscriptionFormatterTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw TestFailure.failed("usage: tests <mihomo> <workdir>") }
        let coreURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let normalized = SubscriptionDownloader.normalizedURL(from: " <https://example.com/sub?a=1&amp;b=2> "),
              normalized.absoluteString == "https://example.com/sub?a=1&b=2" else {
            throw TestFailure.failed("subscription URL normalization failed")
        }
        let request = SubscriptionDownloader.makeRequest(url: normalized, userAgent: SubscriptionDownloader.clientUserAgents[0])
        guard request.value(forHTTPHeaderField: "User-Agent") == "Clash.Meta",
              request.value(forHTTPHeaderField: "Referer") == "https://example.com/" else {
            throw TestFailure.failed("subscription request headers failed")
        }

        let mockConfiguration = URLSessionConfiguration.ephemeral
        mockConfiguration.protocolClasses = [FallbackURLProtocol.self]
        let downloaded = try await SubscriptionDownloader.download(from: normalized, baseConfiguration: mockConfiguration)
        guard downloaded.clientProfile == 3,
              FallbackURLProtocol.observedUserAgents == SubscriptionDownloader.clientUserAgents else {
            throw TestFailure.failed("HTTP 403 client fallback failed")
        }
        print("PASS download: HTTP 403 client fallback")

        let full = """
        mixed-port: 0
        mode: rule
        proxies: []
        proxy-groups:
          - name: 节点选择
            type: select
            proxies: [DIRECT]
        rules:
          - MATCH,DIRECT
        """
        let provider = """
        proxies:
          - name: Local Test
            type: ss
            server: 127.0.0.1
            port: 8388
            cipher: aes-128-gcm
            password: test
        """
        let rawURI = "ss://YWVzLTEyOC1nY206dGVzdA@127.0.0.1:8388#Local%20SS"
        let encoded = Data(rawURI.utf8).base64EncodedString()
        let ssrPassword = Data("test".utf8).base64EncodedString()
        let ssrName = Data("Local SSR".utf8).base64EncodedString()
        let ssrPayload = "127.0.0.1:8389:origin:aes-128-cfb:plain:\(ssrPassword)/?remarks=\(ssrName)"
        let rawSSR = "ssr://\(Data(ssrPayload.utf8).base64EncodedString())"

        let cases: [(String, Data, String)] = [
            ("full", Data(full.utf8), "Clash/Mihomo 配置"),
            ("provider", Data(provider.utf8), "代理提供者订阅"),
            ("uri", Data(rawURI.utf8), "节点链接订阅"),
            ("base64", Data(encoded.utf8), "节点链接订阅"),
            ("ssr", Data(rawSSR.utf8), "节点链接订阅")
        ]

        for (id, input, expectedLabel) in cases {
            let caseDirectory = root.appendingPathComponent(id, isDirectory: true)
            let providersDirectory = caseDirectory.appendingPathComponent("Providers", isDirectory: true)
            try FileManager.default.createDirectory(at: providersDirectory, withIntermediateDirectories: true)
            let prepared = try SubscriptionFormatter.prepare(data: input, id: id)
            guard prepared.label == expectedLabel else { throw TestFailure.failed("\(id): unexpected format \(prepared.label)") }
            let configURL = caseDirectory.appendingPathComponent("config.yaml")
            try prepared.configData.write(to: configURL, options: .atomic)
            if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
                try providerData.write(to: providersDirectory.appendingPathComponent(providerFileName), options: .atomic)
            }
            try validate(coreURL: coreURL, configURL: configURL, dataDirectory: caseDirectory)
            print("PASS \(id): \(prepared.label)")
        }

        do {
            _ = try SubscriptionFormatter.prepare(data: Data("not a subscription".utf8), id: "invalid")
            throw TestFailure.failed("invalid input should be rejected")
        } catch is SubscriptionFormatError {
            print("PASS invalid: rejected")
        }
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
            let detail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown Mihomo error"
            throw TestFailure.failed("Mihomo rejected \(configURL.lastPathComponent): \(detail)")
        }
    }
}
