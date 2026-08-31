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

                Section(header: Text("路径映射"),
                        footer: Text("qB 任务保存路径的前缀（如 /Video），去掉后会拼到 FileBrowser 根目录。例如 qB 的 /Video/Movie/xx.mkv 对应 FileBrowser 的 /Movie/xx.mkv。")) {
                    TextField("qB 路径前缀", text: $settings.pathPrefix)
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
