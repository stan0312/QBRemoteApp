import Foundation
import Network

/// 本地 HTTP 代理服务器（多连接分段 + 流式加速版）
///
/// 用途：filebrowser 的文件流需要 X-Auth 认证，且返回的 Content-Type 是 application/octet-stream，
/// 导致 AVPlayer / VLC 无法正确识别视频格式。本代理在 App 内起一个 127.0.0.1 的本地 HTTP 服务，
/// 把「带认证的 filebrowser 文件流」转发成「无需认证 + 正确 MIME 的本地 URL」。
///
/// 加速原理：运营商/链路的限速通常是「按单条 TCP 连接」级的。播放器请求本地代理时，代理把文件按
/// 字节切成若干段（每段 4MB），用多条并发连接各自带 Range 请求从 filebrowser 拉取，再按段序号
/// 顺序喂给播放器 —— 多条连接各自叠加带宽，绕过单连接限速。
///
/// 流式要点：响应头在第一个分段返回时立即转发、分段的数据块到达即按序转发（不等待整段下载完），
/// 保证首屏快速出画面，同时后台持续用多连接预取。
///
/// v12 增加：支持免认证的分享链接（token 传 nil 则不加 X-Auth）；响应统一带 CORS 头，允许
/// WKWebView 内 file:// 页面的 JS 用 fetch 多连接 Range 拉流（供 MSE 播放器使用）。
final class LocalProxyServer {
    static let shared = LocalProxyServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    /// 会话 key -> (上游 URL, X-Auth token，nil 表示免认证的分享链接)
    private var sessions: [String: (URL, String?)] = [:]
    /// 进行中的下载引擎（URLSession delegate 是弱引用，需强持有到完成）
    private var activeEngines: [MultiSegmentDownloader] = []
    private let queue = DispatchQueue(label: "qb.localproxy")
    private var started = false

    private init() {}

    /// 启动本地代理（幂等）
    func start() {
        queue.sync {
            guard !started else { return }
            started = true
            do {
                let params = NWParameters.tcp
                listener = try NWListener(using: params, on: .any)
                listener?.newConnectionHandler = { [weak self] conn in
                    self?.handleConnection(conn)
                }
                listener?.stateUpdateHandler = { [weak self] state in
                    if case .ready = state {
                        self?.port = self?.listener?.port?.rawValue ?? 0
                        print("[QBProxy] 本地代理已启动，端口 \(self?.port ?? 0)")
                    }
                }
                listener?.start(queue: queue)
            } catch {
                print("[QBProxy] 启动失败: \(error)")
            }
        }
    }

    /// 注册一个要播放的文件，返回本地 URL；代理尚未就绪时返回 nil（调用方可稍后重试）
    /// - Parameter token: filebrowser 的 X-Auth token；分享链接（免认证）传 nil
    func register(targetURL: URL, token: String?) -> String? {
        var result: String?
        queue.sync {
            guard port != 0 else { result = nil; return }
            let key = UUID().uuidString
            sessions[key] = (targetURL, token)
            result = "http://127.0.0.1:\(port)/stream?k=\(key)"
        }
        return result
    }

    /// 本地代理的根地址（供 MSE 播放器页面同源加载）；未就绪时返回 nil
    var baseURL: String? {
        queue.sync { port != 0 ? "http://127.0.0.1:\(port)/" : nil }
    }

    // MARK: - 连接处理

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let buf = buffer + data
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                    self.handleRequest(head, connection: conn, body: Data(buf[range.upperBound...]))
                } else {
                    self.receiveRequest(conn, buffer: buf)
                }
            } else if isComplete || error != nil {
                conn.cancel()
            }
        }
    }

    private func handleRequest(_ head: String, connection: NWConnection, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { sendSimple(connection, code: 400, body: "bad request"); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { sendSimple(connection, code: 400, body: "bad request"); return }
        let method = String(parts[0])

        // CORS 预检：fetch 带 Range 头会先发 OPTIONS
        if method == "OPTIONS" {
            sendOptions(connection)
            return
        }
        guard method == "GET" else {
            sendSimple(connection, code: 405, body: "only GET supported")
            return
        }
        let path = String(parts[1])

        // MSE 播放器静态页面（同源加载，避免 file:// fetch 限制）
        if path == "/player.html" || path == "/player" || path == "/" {
            serveBundleFile(connection, resource: "player.html", subpath: "player", mime: "text/html; charset=utf-8")
            return
        }
        if path == "/mp4box.all.js" {
            serveBundleFile(connection, resource: "mp4box.all.js", subpath: "player", mime: "application/javascript")
            return
        }

        var rangeStart: Int64 = 0
        var rangeEnd: Int64? = nil
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                let r = line.split(separator: ":", maxSplits: 1).map(String.init)[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body2 = r.replacingOccurrences(of: "bytes=", with: "").trimmingCharacters(in: .whitespaces)
                let seg = body2.split(separator: "-").map(String.init)
                if seg.count >= 1, let s = Int64(seg[0].trimmingCharacters(in: .whitespaces)) {
                    rangeStart = s
                }
                if seg.count >= 2, !seg[1].isEmpty, let e = Int64(seg[1].trimmingCharacters(in: .whitespaces)) {
                    rangeEnd = e
                }
            }
        }

        guard let comps = URLComponents(string: "http://x" + path),
              let k = comps.queryItems?.first(where: { $0.name == "k" })?.value,
              let session = sessions[k] else {
            sendSimple(connection, code: 404, body: "not found")
            return
        }
        forward(connection, target: session.0, token: session.1, start: rangeStart, end: rangeEnd)
    }

    // MARK: - 转发（多连接分段）

    private func forward(_ conn: NWConnection, target: URL, token: String?, start: Int64, end: Int64?) {
        let engine = MultiSegmentDownloader(conn: conn, target: target, token: token,
                                            start: start, explicitEnd: end, queue: queue,
                                            contentType: Self.mimeType(for: target))
        activeEngines.append(engine)
        engine.onComplete = { [weak self, weak engine] in
            guard let self = self, let engine = engine else { return }
            self.queue.async {
                self.activeEngines.removeAll { $0 === engine }
            }
        }
        engine.start()
    }

    private func sendSimple(_ conn: NWConnection, code: Int, body: String) {
        let payload = "HTTP/1.1 \(code) X\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendOptions(_ conn: NWConnection) {
        let payload = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Range, Content-Type\r\nAccess-Control-Max-Age: 86400\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 从 App bundle 返回静态资源（MSE 播放器页面与其依赖的 JS）
    private func serveBundleFile(_ conn: NWConnection, resource: String, subpath: String, mime: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: subpath),
              let data = try? Data(contentsOf: url) else {
            sendSimple(conn, code: 404, body: "not found")
            return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(data)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 根据文件扩展名返回正确的 MIME（覆盖 filebrowser 返回的 application/octet-stream）
    static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        case "mpg", "mpeg": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "aac": return "audio/aac"
        case "ogg", "oga": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "wma": return "audio/x-ms-wma"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return nil
        }
    }
}

/// 多连接分段下载引擎：把一个 Range 切成多段并发拉取，数据块按序流式输出给本地连接
private final class MultiSegmentDownloader: NSObject {
    let conn: NWConnection
    let queue: DispatchQueue
    let target: URL
    let token: String?
    let requestStart: Int64
    let explicitEnd: Int64?
    let contentType: String?
    var onComplete: (() -> Void)?

    /// 每段大小与并发数（8 × 2MB ≈ 16MB 缓冲上限，兼顾速度与内存）
    private static let SEG_SIZE: Int64 = 2 * 1024 * 1024
    private static let CONCURRENCY = 8

    private var nextStart: Int64
    private var nextSeq = 0
    /// 当前正在转发给播放器的段序号
    private var currentSeq = 0
    private var activeCount = 0
    private var endReached = false
    private var failed = false
    private var failed416 = false
    private var headerPrepared = false
    private var headerSent = false
    private var responseHeader: String?
    /// 还没轮到转发的段的数据缓冲（seq -> 已到达的数据块）
    private var pendingData: [Int: Data] = [:]
    /// 强持有正在下载的段（URLSession delegate 是弱引用）
    private var activeSegments: [Int: SegmentDownloader] = [:]

    init(conn: NWConnection, target: URL, token: String?, start: Int64,
         explicitEnd: Int64?, queue: DispatchQueue, contentType: String?) {
        self.conn = conn
        self.target = target
        self.token = token
        self.requestStart = start
        self.explicitEnd = explicitEnd
        self.queue = queue
        self.contentType = contentType
        self.nextStart = start
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.launchUpTo()
        }
    }

    // MARK: - 分段

    private func launchUpTo() {
        while activeCount < Self.CONCURRENCY && !endReached && !failed {
            launchOne()
        }
    }

    private func launchOne() {
        let segStart = nextStart
        if let end = explicitEnd, segStart > end {
            endReached = true
            return
        }
        let segEnd: Int64
        if let end = explicitEnd {
            segEnd = min(segStart + Self.SEG_SIZE - 1, end)
        } else {
            segEnd = segStart + Self.SEG_SIZE - 1
        }
        nextStart = segEnd + 1
        let seq = nextSeq
        nextSeq += 1
        activeCount += 1
        let dl = SegmentDownloader(seq: seq, segStart: segStart, segEnd: segEnd,
                                   owner: self, token: token, target: target)
        activeSegments[seq] = dl
        dl.start()
    }

    // MARK: - 段回调（均在 queue 上执行）

    /// 段响应头到达：第一时间构造并发送响应头（不等待数据）
    func onSegmentHeader(seq: Int, status: Int, totalSize: Int64?) {
        if failed || headerSent { return }
        if status == 416 {
            prepareHeader416()
            sendData(Data(responseHeader!.utf8))
            headerSent = true
            // 416 无 body，发完响应头立即关闭连接
            failAndCleanup()
            return
        } else if status == 206 || status == 200 {
            if !prepareHeader(totalSize: totalSize) {
                // 请求位置超出文件末尾（requestStart >= total）
                sendData(Data(responseHeader!.utf8))
                headerSent = true
                failAndCleanup()
                return
            }
        } else {
            failAndCleanup()
            return
        }
        sendData(Data(responseHeader!.utf8))
        headerSent = true
    }

    /// 段数据块到达：当前段直接转发，后续段缓冲
    func onSegmentData(seq: Int, block: Data) {
        if failed { return }
        if seq < currentSeq { return }
        if seq == currentSeq {
            sendData(block)
        } else {
            if pendingData[seq] == nil { pendingData[seq] = Data() }
            pendingData[seq]?.append(block)
        }
    }

    /// 段下载完成
    func onSegmentDone(seq: Int, isShort: Bool) {
        activeSegments.removeValue(forKey: seq)
        activeCount -= 1
        if failed { return }
        if isShort {
            endReached = true
        }
        if seq == currentSeq {
            advanceAfterDone()
        }
        if !endReached {
            launchUpTo()
        }
        checkFinish()
    }

    /// 当前段结束后，切换到下一个段并发出其已缓冲的数据
    private func advanceAfterDone() {
        while true {
            let next = currentSeq + 1
            if next >= nextSeq {
                currentSeq = nextSeq
                break
            }
            currentSeq = next
            if let buf = pendingData.removeValue(forKey: next), !buf.isEmpty {
                sendData(buf)
            }
            if activeSegments[next] != nil {
                // 下一段仍在下载：其后续数据块会直接转发
                break
            }
            // 下一段已结束：继续推进
        }
    }

    // MARK: - 响应头

    private func prepareHeader(totalSize: Int64?) -> Bool {
        var h = "HTTP/1.1 206 X\r\n"
        if let ct = contentType { h += "Content-Type: \(ct)\r\n" }
        if let total = totalSize, total > 0 {
            if requestStart >= total {
                prepareHeader416()
                return false
            }
            let actualLast: Int64
            if let e = explicitEnd {
                actualLast = min(e, total - 1)
            } else {
                actualLast = total - 1
            }
            let contentLength = actualLast - requestStart + 1
            h += "Content-Range: bytes \(requestStart)-\(actualLast)/\(total)\r\n"
            h += "Content-Length: \(contentLength)\r\n"
        }
        h += "Accept-Ranges: bytes\r\n"
        // CORS：允许 WKWebView 内页面跨源读取（同源时无影响，跨源时生效）
        h += "Access-Control-Allow-Origin: *\r\n"
        h += "Access-Control-Expose-Headers: Content-Range, Accept-Ranges\r\n"
        h += "Connection: close\r\n\r\n"
        responseHeader = h
        headerPrepared = true
        return true
    }

    private func prepareHeader416() {
        responseHeader = "HTTP/1.1 416 X\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        headerPrepared = true
        failed416 = true
        endReached = true
    }

    // MARK: - 输出与结束

    private func sendData(_ data: Data) {
        guard !data.isEmpty else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                if error != nil {
                    self?.failAndCleanup()
                }
            }
        })
    }

    private func checkFinish() {
        if endReached && currentSeq >= nextSeq && activeCount == 0 {
            finish()
        }
    }

    private func finish() {
        conn.cancel()
        onComplete?()
        onComplete = nil
    }

    private func failAndCleanup() {
        failed = true
        for (_, dl) in activeSegments {
            dl.cancel()
        }
        activeSegments.removeAll()
        pendingData.removeAll()
        conn.cancel()
        onComplete?()
        onComplete = nil
    }
}

/// 单个段的下载器：请求一个 Range，把数据块实时回调给引擎
private final class SegmentDownloader: NSObject, URLSessionDataDelegate {
    let seq: Int
    let segStart: Int64
    let segEnd: Int64
    weak var owner: MultiSegmentDownloader?
    let token: String?
    let target: URL
    var session: URLSession?
    var task: URLSessionDataTask?
    private var statusCode = 0
    private var totalSize: Int64?
    private var received = 0

    init(seq: Int, segStart: Int64, segEnd: Int64, owner: MultiSegmentDownloader,
         token: String?, target: URL) {
        self.seq = seq
        self.segStart = segStart
        self.segEnd = segEnd
        self.owner = owner
        self.token = token
        self.target = target
    }

    func start() {
        var req = URLRequest(url: target)
        if let token = token, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Auth")
        }
        req.setValue("bytes=\(segStart)-\(segEnd)", forHTTPHeaderField: "Range")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = http.statusCode
        if let cr = http.value(forHTTPHeaderField: "Content-Range") {
            let parts = cr.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
            if let last = parts.last, let tot = Int64(last) {
                totalSize = tot
            }
        }
        let status = statusCode
        let total = totalSize
        owner?.queue.async { [weak self] in
            guard let self = self else { return }
            self.owner?.onSegmentHeader(seq: self.seq, status: status, totalSize: total)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        let seq = self.seq
        owner?.queue.async { [weak self] in
            guard let self = self else { return }
            self.owner?.onSegmentData(seq: seq, block: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let reqLen = segEnd - segStart + 1
        let isShort = Int64(received) < reqLen
        let seq = self.seq
        owner?.queue.async { [weak self] in
            guard let self = self else { return }
            self.owner?.onSegmentDone(seq: seq, isShort: isShort)
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }
}
