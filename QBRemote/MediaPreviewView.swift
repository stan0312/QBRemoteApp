import SwiftUI
import AVKit
import AVFoundation

/// 媒体预览页：视频 / 音频 / 图片
/// - mp4/mov/m4v 等：App 内 AVPlayer 直接播放（带 X-Auth 认证）
/// - mkv 等 iOS 原生不支持的容器：用 VLC（WebDAV Basic 认证）打开，或保存到文件 App
struct MediaPreviewView: View {
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    let file: TorrentFile
    let torrent: TorrentInfo
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var imageError = false
    @State private var showShare = false
    @State private var localFileURL: URL?
    @State private var downloading = false
    @State private var downloadError: String?

    /// FileBrowser raw URL（App 内认证播放）
    private var rawURL: URL? {
        fb.rawURL(savePath: torrent.save_path, relativeName: file.name, prefix: settings.pathPrefix)
    }

    /// WebDAV URL（VLC 用）
    private var davURL: URL? {
        fb.davURL(savePath: torrent.save_path, relativeName: file.name, prefix: settings.pathPrefix,
                  username: settings.fbUsername, password: settings.fbPassword)
    }

    /// AVPlayer 是否原生支持该格式（MKV/AVI/WMV/FLV/WebM 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v", "3gp", "m4a"].contains(file.fileExtension)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if file.isImage {
                imageContent
            } else if file.isVideo || file.isAudio {
                if file.isVideo, !isNativePlayable {
                    unsupportedContent
                } else {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(12)
            }
        }
        .onAppear {
            setupPlayback()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .sheet(isPresented: $showShare) {
            if let url = localFileURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - 图片

    @ViewBuilder
    private var imageContent: some View {
        if let image = image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding()
        } else if imageError {
            VStack(spacing: 10) {
                Text("图片加载失败")
                    .foregroundColor(.white)
                if let url = rawURL {
                    Button("用浏览器打开") {
                        UIApplication.shared.open(url)
                    }
                    .foregroundColor(.blue)
                }
            }
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    // MARK: - 不支持的视频格式（MKV 等）

    @ViewBuilder
    private var unsupportedContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text(".\(file.fileExtension) 格式")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text("iOS 原生播放器不支持 .\(file.fileExtension) 容器，\n可通过 VLC 播放或保存到本地。")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let vlcURL = vlcCallbackURL {
                Button {
                    UIApplication.shared.open(vlcURL)
                } label: {
                    Label("用 VLC 播放", systemImage: "play.circle.fill")
                        .padding()
                        .frame(maxWidth: 260)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                Text("需在 App Store 安装免费的 VLC 播放器")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }

            Button {
                downloadAndSave()
            } label: {
                if downloading {
                    HStack {
                        ProgressView().tint(.white)
                        Text("下载中...")
                    }
                    .padding()
                    .frame(maxWidth: 260)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                } else {
                    Label("保存到文件", systemImage: "square.and.arrow.down")
                        .padding()
                        .frame(maxWidth: 260)
                        .background(Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .disabled(downloading)

            if let downloadError = downloadError {
                Text(downloadError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// VLC x-callback 唤起 URL
    private var vlcCallbackURL: URL? {
        guard let dav = davURL else { return nil }
        return fb.vlcOpenURL(davURL: dav)
    }

    /// 下载到本地临时文件，然后通过分享面板保存到"文件"App
    private func downloadAndSave() {
        guard let url = rawURL, let token = fb.token else {
            downloadError = "FileBrowser 未登录或地址错误"
            return
        }
        downloading = true
        downloadError = nil
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.downloadTask(with: req) { tempURL, resp, err in
            DispatchQueue.main.async {
                downloading = false
                if let err = err {
                    downloadError = "下载失败: \(err.localizedDescription)"
                    return
                }
                guard let tempURL = tempURL else {
                    downloadError = "下载失败"
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(file.fileName)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    localFileURL = dest
                    showShare = true
                } catch {
                    downloadError = "保存失败: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    // MARK: - 初始化播放

    private func setupPlayback() {
        guard let url = rawURL, let token = fb.token else { return }

        if file.isImage {
            loadImage(url: url, token: token)
        } else if file.isVideo || file.isAudio {
            // 带 X-Auth header 播放（AVPlayer 支持格式）
            let headers = ["X-Auth": token]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
        }
    }

    private func loadImage(url: URL, token: String) {
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let data = data, let img = UIImage(data: data) {
                    self.image = img
                } else {
                    self.imageError = true
                }
            }
        }.resume()
    }
}

/// 系统分享面板（保存到文件 / 分享给第三方）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
