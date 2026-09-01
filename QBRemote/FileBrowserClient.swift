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

    /// 计算 filebrowser 相对路径（含映射规则）
    /// - Parameters:
    ///   - savePath: qB 的保存路径（如 /vol2/1000/Download/Movie）
    ///   - relativeName: 文件在种子内的相对路径（如 电影/xxx.mkv）
    ///   - prefix: 手动配置的前缀（如 /Movie）；为空则自动用 save_path 的最后一段作为 filebrowser 顶层目录
    func fbRelativePath(savePath: String, relativeName: String, prefix: String) -> String {
        if !prefix.isEmpty {
            // 手动模式：完整路径（savePath + 相对名）去掉 prefix 前缀
            var full = savePath
            if !full.hasSuffix("/") { full += "/" }
            full += relativeName
            if full.hasPrefix(prefix) {
                var rel = String(full.dropFirst(prefix.count))
                if !rel.hasPrefix("/") { rel = "/" + rel }
                return rel
            }
        }
        // 自动模式：qB save_path 的最后一段（如 Movie）映射为 filebrowser 顶层目录
        let last = (savePath as NSString).lastPathComponent
        var rel = relativeName
        if !rel.hasPrefix("/") { rel = "/" + rel }
        return "/" + last + rel
    }

    /// 构造 FileBrowser 可访问的 raw URL（带 X-Auth 认证，App 内播放用）
    func rawURL(savePath: String, relativeName: String, prefix: String) -> URL? {
        let rel = fbRelativePath(savePath: savePath, relativeName: relativeName, prefix: prefix)
        guard let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: baseURL + "/api/raw" + encoded)
    }

    /// 构造 WebDAV URL（Basic 认证内嵌，供 VLC 等第三方播放器使用）
    func davURL(savePath: String, relativeName: String, prefix: String,
                username: String, password: String) -> URL? {
        let rel = fbRelativePath(savePath: savePath, relativeName: relativeName, prefix: prefix)
        guard let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let base = URL(string: baseURL),
              let host = base.host else {
            return nil
        }
        let port = base.port.map { ":\($0)" } ?? ""
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        return URL(string: "webdav://\(user):\(pass)@\(host)\(port)/dav\(encoded)")
    }

    /// 生成唤起 VLC 的 x-callback URL（stream 播放远程 WebDAV 文件）
    func vlcOpenURL(davURL: URL) -> URL? {
        guard let enc = davURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "vlc-x-callback://x-callback-url/stream?url=" + enc)
    }

    /// 带认证（X-Auth header）的 URLRequest，用于加载图片等
    func authorizedRequest(for url: URL) -> URLRequest? {
        guard let token = token else { return nil }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        return req
    }

    /// 删除 filebrowser 中的文件/目录（DELETE /api/resources/<相对路径>，需 X-Auth）
    func deleteResource(relativePath: String) async throws {
        guard let token = token else { throw FBError.invalidToken }
        var rel = relativePath
        if !rel.hasPrefix("/") { rel = "/" + rel }
        guard let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/resources" + encoded) else {
            throw FBError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        let (_, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw FBError.serverError(http.statusCode)
        }
    }

    /// Basic 认证头（用于 WebDAV 下载等）
    func basicAuthHeader(username: String, password: String) -> String? {
        let s = "\(username):\(password)"
        guard let data = s.data(using: .utf8) else { return nil }
        return "Basic " + data.base64EncodedString()
    }

    /// 创建免认证公开分享链接（返回 hash 与公开 URL）
    /// 分享 URL 无需 X-Auth、支持 HTTP Range，可被 SenPlayer / VidHub / Filebar 等第三方播放器直接打开
    func createShare(relativePath: String, hours: Int = 24) async throws -> (hash: String, url: String)? {
        guard let token = token else { throw FBError.invalidToken }
        var rel = relativePath
        if !rel.hasPrefix("/") { rel = "/" + rel }
        guard let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: baseURL + "/api/share" + encoded + "?expires=\(hours)&unit=hours") else {
            throw FBError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"password":""}"#.utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw FBError.serverError(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = obj["hash"] as? String, !hash.isEmpty else {
            return nil
        }
        return (hash, baseURL + "/api/public/dl/" + hash)
    }

    /// 删除分享链接（清理用）
    func deleteShare(hash: String) async throws {
        guard let token = token else { throw FBError.invalidToken }
        guard let url = URL(string: baseURL + "/api/share/" + hash) else { throw FBError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        let (_, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw FBError.serverError(http.statusCode)
        }
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
