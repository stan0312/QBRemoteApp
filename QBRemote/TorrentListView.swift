import SwiftUI

/// 任务列表页
struct TorrentListView: View {
    @ObservedObject var qb: QBClient
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    @State private var torrents: [TorrentInfo] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if torrents.isEmpty && isLoading {
                    ProgressView("正在加载任务...")
                } else if torrents.isEmpty && !(errorText?.isEmpty ?? true) {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(errorText!)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if torrents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无任务")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(torrents) { t in
                        NavigationLink(destination: TorrentDetailView(qb: qb, fb: fb, settings: settings, torrent: t)) {
                            TorrentRow(torrent: t)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("下载任务")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            // 确保已登录
            if !qb.isLoggedIn {
                let ok = try await qb.login(username: settings.qbUsername,
                                            password: settings.qbPassword)
                if !ok {
                    errorText = "qB 登录失败，请检查账号密码"
                    isLoading = false
                    return
                }
            }
            torrents = try await qb.fetchTorrents()
            // 按添加时间倒序
            torrents.sort { $0.added_on > $1.added_on }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

/// 单个任务行
struct TorrentRow: View {
    let torrent: TorrentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(torrent.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            HStack {
                Text(torrent.stateText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if torrent.dlspeed > 0 {
                    Text("↓ " + formatSpeed(torrent.dlspeed))
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if torrent.upspeed > 0 {
                    Text("↑ " + formatSpeed(torrent.upspeed))
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            ProgressView(value: torrent.progress)
                .tint(progressColor)

            HStack {
                Text("\(Int(torrent.progress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatSize(torrent.downloaded) + " / " + formatSize(torrent.size))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var progressColor: Color {
        switch torrent.state {
        case "uploading", "stalledUP", "pausedUP", "stoppedUP", "queuedUP", "forcedUP":
            return .green
        case "downloading", "stalledDL", "forcedDL", "metaDL", "queuedDL":
            return .blue
        case "error", "missingFiles":
            return .red
        default:
            return .gray
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatSpeed(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB/s", Double(bytes) / 1024 / 1024)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB/s", Double(bytes) / 1024)
        } else {
            return "\(bytes) B/s"
        }
    }
}
