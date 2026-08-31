import Foundation
import Network

/// 本地 HTTP 代理服务器
///
/// 用途：VLC 无法给请求附加 X-Auth header，而 filebrowser 的文件流需要 X-Auth 认证。
/// 本代理在 App 内起一个 127.0.0.1 的本地 HTTP 服务，把「带认证的 filebrowser 文件流」
/// 转发成「无需认证的本地 URL」，供 VLC 播放 MKV 等格式。支持 Range（可拖动进度）。
final class LocalProxyServer {
    static let shared = LocalProxyServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    /// 会话 key -> (上游 URL, X-Auth token)
    private var sessions: [String: (URL, String)] = [:]
    /// 进行中的转发器（URLSession delegate 是弱引用，需强持有到完成）
    private var activeForwarders: [StreamForwarder] = []
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
    func register(targetURL: URL, token: String) -> String? {
        var result: String?
        queue.sync {
            guard port != 0 else { result = nil; return }
            let key = UUID().uuidString
            sessions[key] = (targetURL, token)
            result = "http://127.0.0.1:\(port)/stream?k=\(key)"
        }
        return result
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
                var buf = buffer + data
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                    let body = Data(buf[range.upperBound...])
                    self.handleRequest(head, connection: conn, body: body)
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
        guard parts.count >= 2, parts[0] == "GET" else {
            sendSimple(connection, code: 405, body: "only GET supported")
            return
        }
        let path = String(parts[1])

        var range: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                range = line.split(separator: ":", maxSplits: 1).map(String.init)[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let comps = URLComponents(string: "http://x" + path),
              let k = comps.queryItems?.first(where: { $0.name == "k" })?.value,
              let session = sessions[k] else {
            sendSimple(connection, code: 404, body: "not found")
            return
        }
        forward(connection, target: session.0, token: session.1, range: range)
    }

    // MARK: - 转发

    private func forward(_ conn: NWConnection, target: URL, token: String, range: String?) {
        var req = URLRequest(url: target)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        if let range = range {
            req.setValue(range, forHTTPHeaderField: "Range")
        }
        let forwarder = StreamForwarder(conn: conn)
        activeForwarders.append(forwarder)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: cfg, delegate: forwarder, delegateQueue: nil)
        forwarder.session = session
        forwarder.onComplete = { [weak self, weak forwarder] in
            guard let self = self, let forwarder = forwarder else { return }
            self.queue.async {
                self.activeForwarders.removeAll { $0 === forwarder }
            }
        }
        forwarder.task = session.dataTask(with: req)
        forwarder.task?.resume()
    }

    private func sendSimple(_ conn: NWConnection, code: Int, body: String) {
        let payload = "HTTP/1.1 \(code) X\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

/// 流式转发：把 URLSession 的数据流式写给 NWConnection
private final class StreamForwarder: NSObject, URLSessionDataDelegate {
    let conn: NWConnection
    var task: URLSessionDataTask?
    var session: URLSession?
    var onComplete: (() -> Void)?
    private var sentHeader = false
    private var failed = false

    init(conn: NWConnection) {
        self.conn = conn
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failed = true
            completionHandler(.cancel)
            return
        }
        // 转发响应头（保留 Range 需要的字段）
        var header = "HTTP/1.1 \(http.statusCode) X\r\n"
        for key in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag", "Content-Disposition"] {
            if let v = http.value(forHTTPHeaderField: key) {
                header += "\(key): \(v)\r\n"
            }
        }
        if http.value(forHTTPHeaderField: "Content-Length") == nil {
            header += "Transfer-Encoding: chunked\r\n"
        }
        header += "Connection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        sentHeader = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !failed else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.failed = true
                self?.task?.cancel()
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 结束后关闭本地连接
        conn.cancel()
        onComplete?()
    }
}
