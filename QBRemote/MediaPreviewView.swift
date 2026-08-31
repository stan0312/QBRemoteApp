import SwiftUI
import AVKit
import AVFoundation

/// 媒体预览页：视频 / 音频 / 图片
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

    /// qB 完整路径（save_path + 文件相对路径）
    private var qbFullPath: String {
        var p = torrent.save_path
        if !p.hasSuffix("/") { p += "/" }
        return p + file.name
    }

    /// FileBrowser raw URL
    private var rawURL: URL? {
        fb.rawURL(forQbPath: qbFullPath, prefix: settings.pathPrefix)
    }

    /// AVPlayer 是否原生支持该格式（MKV 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v"].contains(file.fileExtension)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if file.isImage {
                imageContent
            } else if file.isVideo || file.isAudio {
                videoAudioContent
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

    // MARK: - 视频 / 音频

    @ViewBuilder
    private var videoAudioContent: some View {
        if file.isVideo, !isNativePlayable {
            // MKV 等 iOS 原生播放器不支持的格式
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)
                Text("iOS 原生播放器不支持 .\(file.fileExtension) 格式")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("建议用第三方播放器（nPlayer / Infuse / VLC）打开")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if let url = rawURL {
                    Button {
                        showShare = true
                    } label: {
                        Label("分享到其他播放器", systemImage: "square.and.arrow.up")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .sheet(isPresented: $showShare) {
                        ShareSheet(items: [url])
                    }
                }
            }
        } else {
            VideoPlayer(player: player)
                .ignoresSafeArea()
        }
    }

    // MARK: - 初始化播放

    private func setupPlayback() {
        guard let url = rawURL, let token = fb.token else { return }

        if file.isImage {
            loadImage(url: url, token: token)
        } else {
            // 视频/音频：带 X-Auth header 播放
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

/// 系统分享面板（用于 MKV 等分享给第三方播放器）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
