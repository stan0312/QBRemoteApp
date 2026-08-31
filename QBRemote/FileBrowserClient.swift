import Foundation

/// FileBrowser API 客户端
/// 登录获取 JWT token，访问文件时通过 X-Auth header 认证
class FileBrowserClient: ObservableObject {
    @Published var token: String?

    var baseURL: String

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    func updateBaseURL(_ url: String) {
        self.baseURL = url
        self.token = nil
    }

    /// 登录 FileBrowser（POST /api/login，返回 JWT token 字符串）
    func login(username: String, password: String) async throws -> String? {
        guard let url = URL(string: baseURL + "/api/login") else {
            throw FBError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "username": username,
            "password": password,
            "recaptcha": ""
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 403 {
                // 登录接口被反代/WAF 拦截的情况
                throw FBError.loginBlocked
            }
            if http.statusCode >= 400 {
                throw FBError.serverError(http.statusCode)
            }
        }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw FBError.invalidToken }
        self.token = token
        return token
    }

    /// 由 qB 保存路径（含文件名）构造 FileBrowser 可访问的 raw URL
    /// 映射规则：把 pathPrefix 前缀去掉后拼到 /api/raw 后面
    func rawURL(forQbPath qbPath: String, prefix: String) -> URL? {
        var rel = qbPath
        // 去掉前缀（如 /Video）
        if !prefix.isEmpty, rel.hasPrefix(prefix) {
            rel = String(rel.dropFirst(prefix.count))
        }
        if !rel.hasPrefix("/") {
            rel = "/" + rel
        }
        guard let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: baseURL + "/api/raw" + encoded)
    }

    /// 带认证（X-Auth header）的 URLRequest，用于加载图片等
    func authorizedRequest(for url: URL) -> URLRequest? {
        guard let token = token else { return nil }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        return req
    }
}

enum FBError: LocalizedError {
    case invalidURL
    case invalidToken
    case loginBlocked
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "FileBrowser 地址不正确"
        case .invalidToken:
            return "FileBrowser 登录失败"
        case .loginBlocked:
            return "FileBrowser 登录被拦截，请检查是否从外部网络访问"
        case .serverError(let code):
            return "FileBrowser 返回错误（\(code)）"
        }
    }
}
