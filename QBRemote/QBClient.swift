import Foundation

/// qBittorrent Web API 客户端
/// 登录后通过 Cookie 维持会话
class QBClient: ObservableObject {
    @Published var isLoggedIn = false
    @Published var errorMessage: String?

    var baseURL: String

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    func updateBaseURL(_ url: String) {
        self.baseURL = url
        // 切换地址时清空登录态
        self.isLoggedIn = false
    }

    /// 登录 qB（POST /api/v2/auth/login，返回 "Ok."）
    func login(username: String, password: String) async throws -> Bool {
        var comps = URLComponents(string: baseURL)!
        comps.path = "/api/v2/auth/login"
        guard let url = comps.url else {
            throw QBError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        req.httpBody = body.query?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw QBError.serverError(http.statusCode)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let ok = text.contains("Ok")
        isLoggedIn = ok
        return ok
    }

    /// 获取任务列表
    func fetchTorrents() async throws -> [TorrentInfo] {
        guard let url = URL(string: baseURL + "/api/v2/torrents/info?limit=5000") else {
            throw QBError.invalidURL
        }
        let (data, resp) = try await session.data(from: url)
        try checkAuth(resp)
        return try JSONDecoder().decode([TorrentInfo].self, from: data)
    }

    /// 获取某个任务的文件列表
    func fetchFiles(hash: String) async throws -> [TorrentFile] {
        guard var comps = URLComponents(string: baseURL + "/api/v2/torrents/files") else {
            throw QBError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "hash", value: hash)]
        guard let url = comps.url else { throw QBError.invalidURL }

        let (data, resp) = try await session.data(from: url)
        try checkAuth(resp)
        return try JSONDecoder().decode([TorrentFile].self, from: data)
    }

    private func checkAuth(_ resp: URLResponse) throws {
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 403 {
                isLoggedIn = false
                throw QBError.unauthorized
            }
            if http.statusCode >= 400 {
                throw QBError.serverError(http.statusCode)
            }
        }
    }
}

enum QBError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "地址格式不正确"
        case .unauthorized:
            return "登录已失效，请重新登录"
        case .serverError(let code):
            return "服务器返回错误（\(code)）"
        }
    }
}
