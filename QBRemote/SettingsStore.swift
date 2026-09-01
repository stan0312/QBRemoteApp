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
    /// 手动路径前缀（可选）。留空时自动用 qB 保存路径的最后一级目录映射到 FileBrowser 根目录
    @Published var pathPrefix: String
    /// 局域网地址（可选）：家里局域网内直连 NAS 可避开公网 DDNS 链路的限速
    @Published var qbLANURL: String
    @Published var fbLANURL: String
    @Published var useLAN: Bool

    private let defaults = UserDefaults.standard

    init() {
        qbURL = defaults.string(forKey: "qbURL") ?? "http://sdcs.asuscomm.com:8085"
        qbUsername = defaults.string(forKey: "qbUsername") ?? "stan"
        qbPassword = defaults.string(forKey: "qbPassword") ?? ""
        fbURL = defaults.string(forKey: "fbURL") ?? "http://sdcs.asuscomm.com:8033"
        fbUsername = defaults.string(forKey: "fbUsername") ?? "admin"
        fbPassword = defaults.string(forKey: "fbPassword") ?? ""
        pathPrefix = defaults.string(forKey: "pathPrefix") ?? ""
        qbLANURL = defaults.string(forKey: "qbLANURL") ?? ""
        fbLANURL = defaults.string(forKey: "fbLANURL") ?? ""
        useLAN = defaults.bool(forKey: "useLAN")
    }

    /// 设置是否已填完整
    var isConfigured: Bool {
        !qbURL.isEmpty && !qbUsername.isEmpty && !qbPassword.isEmpty
            && !fbURL.isEmpty && !fbUsername.isEmpty && !fbPassword.isEmpty
    }

    /// 实际使用的 qB 地址（开启局域网且已填局域网地址时优先用局域网）
    var activeQBURL: String {
        useLAN && !qbLANURL.isEmpty ? normalized(qbLANURL) : normalized(qbURL)
    }

    /// 实际使用的 FileBrowser 地址
    var activeFBURL: String {
        useLAN && !fbLANURL.isEmpty ? normalized(fbLANURL) : normalized(fbURL)
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
        defaults.set(qbLANURL, forKey: "qbLANURL")
        defaults.set(fbLANURL, forKey: "fbLANURL")
        defaults.set(useLAN, forKey: "useLAN")
    }
}
