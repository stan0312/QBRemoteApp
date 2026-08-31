import Foundation
import Combine

/// App 全局设置（qB 和 FileBrowser 的连接信息）
final class SettingsStore: ObservableObject {
    @Published var qbURL: String
    @Published var qbUsername: String
    @Published var qbPassword: String
    @Published var fbURL: String
    @Published var fbUsername: String
    @Published var fbPassword: String
    /// qB 保存路径前缀，用于映射到 FileBrowser 根目录（如 /Video）
    @Published var pathPrefix: String

    private let defaults = UserDefaults.standard

    init() {
        qbURL = defaults.string(forKey: "qbURL") ?? "http://sdcs.asuscomm.com:8085"
        qbUsername = defaults.string(forKey: "qbUsername") ?? "stan"
        qbPassword = defaults.string(forKey: "qbPassword") ?? ""
        fbURL = defaults.string(forKey: "fbURL") ?? "http://sdcs.asuscomm.com:8033"
        fbUsername = defaults.string(forKey: "fbUsername") ?? "admin"
        fbPassword = defaults.string(forKey: "fbPassword") ?? ""
        pathPrefix = defaults.string(forKey: "pathPrefix") ?? "/Video"
    }

    /// 设置是否已填完整
    var isConfigured: Bool {
        !qbURL.isEmpty && !qbUsername.isEmpty && !qbPassword.isEmpty
            && !fbURL.isEmpty && !fbUsername.isEmpty && !fbPassword.isEmpty
    }

    /// 规范化地址（自动补 http:// 前缀，去掉末尾斜杠）
    func normalized(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") {
            u = "http://" + u
        }
        while u.hasSuffix("/") {
            u.removeLast()
        }
        return u
    }

    func save() {
        defaults.set(qbURL, forKey: "qbURL")
        defaults.set(qbUsername, forKey: "qbUsername")
        defaults.set(qbPassword, forKey: "qbPassword")
        defaults.set(fbURL, forKey: "fbURL")
        defaults.set(fbUsername, forKey: "fbUsername")
        defaults.set(fbPassword, forKey: "fbPassword")
        defaults.set(pathPrefix, forKey: "pathPrefix")
    }
}
