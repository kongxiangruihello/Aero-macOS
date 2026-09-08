import Foundation

struct DownloadedSubscription {
    let data: Data
    let response: HTTPURLResponse
    let clientProfile: Int
}

enum SubscriptionDownloadError: LocalizedError {
    case invalidURL
    case invalidResponse
    case tooLarge
    case htmlResponse(Int)
    case forbidden(String)
    case unauthorized
    case rateLimited
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请输入有效的 HTTP 或 HTTPS 订阅地址"
        case .invalidResponse:
            return "订阅服务器返回了无法识别的响应"
        case .tooLarge:
            return "订阅内容超过 20 MB"
        case .htmlResponse(let status):
            return "订阅服务器返回了网页而不是配置（HTTP \(status)）。请从服务商后台复制“Clash / Mihomo 订阅”链接，不要复制浏览器地址栏中的管理页面地址"
        case .forbidden(let reason):
            return reason
        case .unauthorized:
            return "订阅链接未授权（HTTP 401）。请登录服务商后台重新生成订阅链接"
        case .rateLimited:
            return "订阅服务器请求过于频繁（HTTP 429）。请稍后再试"
        case .httpStatus(let status):
            return "订阅服务器返回 HTTP \(status)"
        }
    }
}

final class SubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let headers: [String: String]

    init(headers: [String: String]) {
        self.headers = headers
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        for (name, value) in headers { redirected.setValue(value, forHTTPHeaderField: name) }
        completionHandler(redirected)
    }
}

enum SubscriptionDownloader {
    static let clientUserAgents = [
        "Clash.Meta",
        "ClashMetaForAndroid/2.11.16.Meta",
        "ClashforWindows/0.20.39"
    ]

    static func normalizedURL(from input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func makeRequest(url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/yaml, text/yaml, text/plain, application/json, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)/", forHTTPHeaderField: "Referer")
        }
        return request
    }

    static func download(from url: URL, baseConfiguration: URLSessionConfiguration = .default) async throws -> DownloadedSubscription {
        var lastForbiddenResponse: (HTTPURLResponse, Data)?

        for (index, userAgent) in clientUserAgents.enumerated() {
            let request = makeRequest(url: url, userAgent: userAgent)
            let headers = request.allHTTPHeaderFields ?? [:]
            let configuration = (baseConfiguration.copy() as? URLSessionConfiguration) ?? .default
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            let redirectDelegate = SubscriptionRedirectDelegate(headers: headers)
            let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
                session.finishTasksAndInvalidate()
            } catch {
                session.invalidateAndCancel()
                throw error
            }

            guard let http = response as? HTTPURLResponse else { throw SubscriptionDownloadError.invalidResponse }
            if http.statusCode == 403 {
                lastForbiddenResponse = (http, data)
                if index < clientUserAgents.count - 1 { continue }
                break
            }
            guard 200..<300 ~= http.statusCode else {
                switch http.statusCode {
                case 401: throw SubscriptionDownloadError.unauthorized
                case 429: throw SubscriptionDownloadError.rateLimited
                default: throw SubscriptionDownloadError.httpStatus(http.statusCode)
                }
            }
            guard data.count < 20_000_000 else { throw SubscriptionDownloadError.tooLarge }
            if isHTML(data: data, response: http) { throw SubscriptionDownloadError.htmlResponse(http.statusCode) }
            return DownloadedSubscription(data: data, response: http, clientProfile: index + 1)
        }

        if let (response, data) = lastForbiddenResponse {
            throw SubscriptionDownloadError.forbidden(forbiddenMessage(response: response, data: data))
        }
        throw SubscriptionDownloadError.invalidResponse
    }

    private static func isHTML(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/html") { return true }
        let prefix = String(data: data.prefix(512), encoding: .utf8)?.lowercased() ?? ""
        return prefix.contains("<!doctype html") || prefix.contains("<html")
    }

    private static func forbiddenMessage(response: HTTPURLResponse, data: Data) -> String {
        let body = String(data: data.prefix(8_192), encoding: .utf8)?.lowercased() ?? ""
        let server = response.value(forHTTPHeaderField: "Server")?.lowercased() ?? ""
        if body.contains("cloudflare") || body.contains("cf-ray") || body.contains("attention required") || server.contains("cloudflare") {
            return "订阅地址被网页防护拦截（HTTP 403）。请从服务商后台生成“Clash / Mihomo 专用订阅”，或联系服务商允许桌面客户端访问"
        }
        if ["expired", "invalid token", "token expired", "subscription expired", "订阅已过期", "套餐已过期", "链接失效"].contains(where: body.contains) {
            return "订阅链接已失效或套餐已过期（HTTP 403）。请登录服务商后台重新生成订阅链接"
        }
        return "订阅服务器拒绝访问（HTTP 403）。已自动尝试 3 种 Clash 客户端身份；请确认套餐和流量有效，并从服务商后台重新复制 Clash / Mihomo 订阅链接"
    }
}
