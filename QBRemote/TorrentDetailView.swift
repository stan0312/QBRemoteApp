import SwiftUI

/// 任务详情：文件列表 + 预览
struct TorrentDetailView: View {
    @ObservedObject var qb: QBClient
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    let torrent: TorrentInfo

    @State private var files: [TorrentFile] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var previewingFile: TorrentFile?

    var body: some View {
        Group {
            if isLoading && files.isEmpty {
                ProgressView("正在加载文件...")
            } else if files.isEmpty && !(errorText?.isEmpty ?? true) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)
                    Text(errorText!)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if files.isEmpty {
                Text("该任务没有文件")
                    .foregroundColor(.secondary)
            } else {
                List(files) { f in
                    Button {
                        handleTap(f)
                    } label: {
                        FileRow(file: f)
                    }
                    .disabled(!f.isPreviewable)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(torrent.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $previewingFile) { file in
            MediaPreviewView(fb: fb, settings: settings, file: file, torrent: torrent)
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            if !qb.isLoggedIn {
                _ = try await qb.login(username: UserDefaults.standard.string(forKey: "qbUsername") ?? "",
                                       password: UserDefaults.standard.string(forKey: "qbPassword") ?? "")
            }
            files = try await qb.fetchFiles(hash: torrent.hash)
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func handleTap(_ file: TorrentFile) {
        guard file.isPreviewable else { return }
        guard fb.token != nil else {
            errorText = "FileBrowser 未登录，请返回设置检查"
            return
        }
        previewingFile = file
    }
}

/// 文件行
struct FileRow: View {
    let file: TorrentFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.iconName)
                .font(.system(size: 20))
                .foregroundColor(file.isPreviewable ? .blue : .gray)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.fileName)
                    .font(.subheadline)
                    .foregroundColor(file.isPreviewable ? .primary : .secondary)
                    .lineLimit(2)

                HStack {
                    Text(formatSize(file.size))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if file.progress < 1.0 {
                        Text("\(Int(file.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if file.isPreviewable {
                        Image(systemName: "play.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                }
            }

            ProgressView(value: file.progress)
                .frame(width: 40)
                .tint(file.progress >= 1.0 ? .green : .blue)
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
