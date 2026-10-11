import Foundation

/// 轻量级调试日志（线程安全环形存储，上限 5000 条，可一键复制导出）
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
    private init() {}

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let tag: String
        let message: String
    }

    func log(_ tag: String, _ message: String) {
        let time = dateFormatter.string(from: Date())
        let entry = LogEntry(time: time, tag: tag, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        #if DEBUG
        print("[\(time)] [\(tag)] \(message)")
        #endif
    }

    var snapshot: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// 导出为可分享的纯文本
    var exportText: String {
        snapshot.map { "[\($0.time)] [\($0.tag)] \($0.message)" }.joined(separator: "\n")
    }
}

/// 全局便捷日志函数（内部统一走 AppLog.shared）
func AppLog(_ tag: String, _ message: String) {
    AppLog.shared.log(tag, message)
}
