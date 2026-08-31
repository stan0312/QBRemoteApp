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

    // MARK: - 任务操作

    /// 暂停任务（hashes 为 "all" 表示全部）
    func pause(hashes: [String]) async throws {
        try await torrentAction(action: "pause", hashes: hashes)
    }

    /// 恢复任务
    func resume(hashes: [String]) async throws {
        try await torrentAction(action: "resume", hashes: hashes)
    }

    /// 重新校验
    func recheck(hashes: [String]) async throws {
        try await torrentAction(action: "recheck", hashes: hashes)
    }

    private func torrentAction(action: String, hashes: [String]) async throws {
        var comps = URLComponents(string: baseURL + "/api/v2/torrents/" + action)!
        comps.queryItems = [URLQueryItem(name: "hashes", value: hashes.isEmpty ? "all" : hashes.joined(separator: "|"))]
        guard let url = comps.url else { throw QBError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await session.data(for: req)
        try checkAuth(resp)
    }

    /// 删除任务
    func delete(hashes: [String], deleteFiles: Bool) async throws {
        var comps = URLComponents(string: baseURL + "/api/v2/torrents/delete")!
        comps.queryItems = [
            URLQueryItem(name: "hashes", value: hashes.joined(separator: "|")),
            URLQueryItem(name: "deleteFiles", value: deleteFiles ? "true" : "false")
        ]
        guard let url = comps.url else { throw QBError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await session.data(for: req)
        try checkAuth(resp)
    }

    // MARK: - 添加任务

    /// 添加磁力链接/HTTP 种子（urls 用换行分隔，可多个）
    func addTorrents(urls: String, savePath: String? = nil, paused: Bool = false) async throws {
        guard var comps = URLComponents(string: baseURL + "/api/v2/torrents/add") else {
            throw QBError.invalidURL
        }
        var items = [URLQueryItem]()
        if !urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "urls", value: urls))
        }
        if let savePath = savePath, !savePath.isEmpty {
            items.append(URLQueryItem(name: "savepath", value: savePath))
        }
        if paused {
            items.append(URLQueryItem(name: "paused", value: "true"))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw QBError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await session.data(for: req)
        try checkAuth(resp)
    }

    /// 上传 .torrent 文件添加任务
    func uploadTorrentFile(fileData: Data, filename: String, savePath: String? = nil, paused: Bool = false) async throws {
        guard let url = URL(string: baseURL + "/api/v2/torrents/add") else {
            throw QBError.invalidURL
        }
        // 构造 multipart/form-data
        let boundary = "----QBRemoteBoundary" + UUID().uuidString
        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if let savePath = savePath, !savePath.isEmpty {
            appendField(name: "savepath", value: savePath)
        }
        if paused {
            appendField(name: "paused", value: "true")
        }
        // 文件字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"torrents\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-bittorrent\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        try checkAuth(resp)
    }

    // MARK: - 传输设置

    /// 设置全局下载限速（KB/s，0 表示不限速）
    func setGlobalDownloadLimit(kbPerSec: Int) async throws {
        try await transferAction(action: "setDownloadLimit", value: kbPerSec)
    }

    /// 设置全局上传限速（KB/s，0 表示不限速）
    func setGlobalUploadLimit(kbPerSec: Int) async throws {
        try await transferAction(action: "setUploadLimit", value: kbPerSec)
    }

    /// 获取当前全局限速
    func fetchTransferInfo() async throws -> TransferInfo {
        guard let url = URL(string: baseURL + "/api/v2/transfer/info") else {
            throw QBError.invalidURL
        }
        let (data, resp) = try await session.data(from: url)
        try checkAuth(resp)
        return try JSONDecoder().decode(TransferInfo.self, from: data)
    }

    private func transferAction(action: String, value: Int) async throws {
        var comps = URLComponents(string: baseURL + "/api/v2/transfer/" + action)!
        comps.queryItems = [URLQueryItem(name: "limit", value: "\(value)")]
        guard let url = comps.url else { throw QBError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, resp) = try await session.data(for: req)
        try checkAuth(resp)
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
