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
    }
}
