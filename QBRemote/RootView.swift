import SwiftUI

/// 主界面：负责连接 qB 和 FileBrowser，然后进入任务列表
struct RootView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var qb = QBClient(baseURL: "")
    @StateObject private var fb = FileBrowserClient(baseURL: "")
    @State private var showSettings = false
    @State private var isConnecting = false
    @State private var connectError: String?

    private var isConnected: Bool {
        qb.isLoggedIn && fb.token != nil
    }

    var body: some View {
        Group {
            if !settings.isConfigured {
                // 首次使用：引导设置
                SettingsView(settings: settings) {
                    connect()
                }
            } else if isConnected {
                TorrentListView(qb: qb, fb: fb, settings: settings)
            } else {
                connectView
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings) {
                connect()
            }
        }
    }

    // MARK: - 连接页

    private var connectView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            if isConnecting {
                ProgressView("正在连接...")
            } else if let err = connectError {
                Text(err)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("重试") { connect() }
                    .buttonStyle(.borderedProminent)
                Button("修改设置") { showSettings = true }
            } else {
                Button("连接") { connect() }
                    .buttonStyle(.borderedProminent)
                Button("修改设置") { showSettings = true }
            }
        }
        .padding()
    }

    // MARK: - 连接逻辑

    private func connect() {
        settings.save()
        connectError = nil
        isConnecting = true

        qb.updateBaseURL(settings.activeQBURL)
        fb.updateBaseURL(settings.activeFBURL)

        Task {
            do {
                // 登录 qB
                let qbOK = try await qb.login(username: settings.qbUsername, password: settings.qbPassword)
                if !qbOK {
                    connectError = "qBittorrent 登录失败，请检查账号密码"
                    isConnecting = false
                    return
                }
                // 登录 FileBrowser
                let fbToken = try await fb.login(username: settings.fbUsername, password: settings.fbPassword)
                if fbToken == nil {
                    connectError = "FileBrowser 登录失败，请检查账号密码"
                    isConnecting = false
                    return
                }
                isConnecting = false
            } catch {
                connectError = error.localizedDescription
                isConnecting = false
            }
        }
    }
}
