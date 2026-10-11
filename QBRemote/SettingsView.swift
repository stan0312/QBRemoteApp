import SwiftUI

/// 设置页面：qB 和 FileBrowser 的连接信息
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var onSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("qBittorrent 下载器")) {
                    TextField("地址", text: $settings.qbURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("用户名", text: $settings.qbUsername)
                        .autocapitalization(.none)
                    SecureField("密码", text: $settings.qbPassword)
                }

                Section(header: Text("FileBrowser 文件服务（用于预览视频/图片）")) {
                    TextField("地址", text: $settings.fbURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("用户名", text: $settings.fbUsername)
                        .autocapitalization(.none)
                    SecureField("密码", text: $settings.fbPassword)
                }

                Section(header: Text("路径映射（可选）"),
                        footer: Text("留空为自动模式：App 自动用 qB 保存路径的最后一级目录映射到 FileBrowser（例如 qB 保存到 /vol2/.../Movie 会对应 FileBrowser 的 /Movie）。仅当自动映射不正确时，才需要手动填写前缀。")) {
                    TextField("留空自动映射", text: $settings.pathPrefix)
                        .autocapitalization(.none)
                }

                Section(header: Text("局域网地址（可选，绕开公网限速）"),
                        footer: Text("在家里 WiFi 下（手机与 NAS 同一局域网）打开此开关并填写内网 IP，App 将走局域网直连，不受外网 DDNS 链路的限速影响，播放更流畅。在外网时请关闭。")) {
                    Toggle("使用局域网地址", isOn: $settings.useLAN)
                    if settings.useLAN {
                        TextField("qB 内网地址（如 http://192.168.1.5:8085）", text: $settings.qbLANURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("FileBrowser 内网地址（如 http://192.168.1.5:8033）", text: $settings.fbLANURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                Section(header: Text("诊断")) {
                    NavigationLink(destination: LogView()) {
                        Label("调试日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.appVersion)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button(action: {
                        settings.save()
                        onSave?()
                        dismiss()
                    }) {
                        Text("保存并连接")
                            .frame(maxWidth: .infinity)
                            .font(.headline.bold())
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .edgeSwipeDismiss { dismiss() }
    }
}

extension Bundle {
    /// 版本号，形如 1.25.10.12 (173042)，用于确认装的是否最新构建
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
