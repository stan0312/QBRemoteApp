import Foundation

/// 轻量级调试日志（线程安全环形存储，上限 5000 条，可一键复制导出）
/// 同时持久化到 Documents/logs/applog.txt —— App 被杀后重启，历史日志依然可查。
/// 用于诊断「远程预览失败」等难以在界面上直接观察的问题。
final class AppLog {
    static let shared = AppLog()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity = 5000
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // 启动时载入上次会话的历史日志（杀 App 重启后依然可见）
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(capacity)
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 2)
            if parts.count == 3 {
                entries.append(LogEntry(time: String(parts[0]),
                                        tag: String(parts[1]),
                                        message: String(parts[2])))
            } else {
                entries.append(LogEntry(time: "", tag: "", message: String(line)))
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let tag: String
        let message: String
    }

    private var logFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("applog.txt")
    }

    func log(_ tag: String, _ message: String) {
        let time = dateFormatter.string(from: Date())
        let entry = LogEntry(time: time, tag: tag, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        let line = "\(time)|\(tag)|\(message)\n"
        lock.unlock()
        appendToFile(line)
        #if DEBUG
        print("[\(time)] [\(tag)] \(message)")
        #endif
    }

    private func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let fh = try FileHandle(forWritingTo: logFileURL)
                defer { try? fh.close() }
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL)
            }
            // 文件超过约 600KB 时截断，只保留最近 5000 行，避免无限增长
            let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if size > 600_000, let text = try? String(contentsOf: logFileURL, encoding: .utf8) {
                let tail = text.split(separator: "\n").suffix(5000).joined(separator: "\n")
                try? tail.data(using: .utf8)?.write(to: logFileURL)
            }
        } catch {
            // 写入失败不阻塞业务
        }
    }

    var snapshot: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    /// 导出为可分享的纯文本（含历史持久化日志）
    var exportText: String {
        snapshot.map { "[\($0.time)] [\($0.tag)] \($0.message)" }.joined(separator: "\n")
    }
}

/// 全局便捷日志函数（与类型名 AppLog 区分，避免重声明冲突）
func Log(_ tag: String, _ message: String) {
    AppLog.shared.log(tag, message)
}
