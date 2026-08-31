import SwiftUI
import AVKit
import AVFoundation
import MobileVLCKit

/// 媒体预览：同级目录左右滑动切换，逐个预览
/// - mp4/mov/m4v 等原生格式：AVPlayer 直接播放（带 X-Auth）
/// - mkv 等 iOS 原生不支持的格式：内置 VLC（经本地代理带认证）播放
/// - 图片：直接显示
struct MediaPreviewView: View {
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    let torrent: TorrentInfo
    let files: [TorrentFile]              // 同级目录中可预览的文件
    @Binding var currentIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var showShare = false
    @State private var localFileURL: URL?
    @State private var downloading = false
    @State private var downloadError: String?

    private var currentFile: TorrentFile { files[min(currentIndex, files.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(files.indices, id: \.self) { i in
                    MediaItemView(file: files[i],
                                  fb: fb,
                                  settings: settings,
                                  torrent: torrent,
                                  showShare: $showShare,
                                  localFileURL: $localFileURL,
                                  downloading: $downloading,
                                  downloadError: $downloadError)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
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
        .overlay(alignment: .top) {
            if files.count > 1 {
                Text("\(currentIndex + 1) / \(files.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(10)
                    .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = localFileURL {
                ShareSheet(items: [url])
            }
        }
    }
}

/// 单个媒体项的显示（一个文件）
struct MediaItemView: View {
    let file: TorrentFile
    @ObservedObject var fb: FileBrowserClient
    @ObservedObject var settings: SettingsStore
    let torrent: TorrentInfo
    @Binding var showShare: Bool
    @Binding var localFileURL: URL?
    @Binding var downloading: Bool
    @Binding var downloadError: String?

    @State private var avPlayer: AVPlayer?
    @State private var audioPlayer: AVPlayer?
    @State private var image: UIImage?
    @State private var imageError = false
    @State private var vlcPlayer: VLCMediaPlayer?
    @State private var vlcReady = false
    @State private var vlcError = false

    private var rawURL: URL? {
        fb.rawURL(savePath: torrent.save_path, relativeName: file.name, prefix: settings.pathPrefix)
    }

    /// AVPlayer 是否原生支持该格式（MKV/AVI/WMV/FLV/WebM 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v", "3gp", "m4a"].contains(file.fileExtension)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private var content: some View {
        if file.isImage {
            imageContent
        } else if file.isAudio {
            audioContent
        } else if file.isVideo {
            if isNativePlayable {
                VideoPlayer(player: avPlayer)
                    .ignoresSafeArea()
            } else {
                vlcContent
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
            VStack(spacing: 12) {
                Text("图片加载失败")
                    .foregroundColor(.white)
                saveButton
            }
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    // MARK: - 音频

    @ViewBuilder
    private var audioContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.8))
            Text(file.fileName)
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(2)
                .padding(.horizontal)
            HStack(spacing: 24) {
                Button {
                    audioPlayer?.pause()
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                Button {
                    audioPlayer?.play()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
            }
            saveButton
        }
        .padding()
    }

    // MARK: - MKV 等非原生视频（内置 VLC）

    @ViewBuilder
    private var vlcContent: some View {
        if let player = vlcPlayer, vlcReady {
            VLCPlayerView(player: player)
                .ignoresSafeArea()
        } else if vlcError {
            VStack(spacing: 14) {
                Image(systemName: "film.stack")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)
                Text("无法播放 .\(file.fileExtension)")
                    .foregroundColor(.white)
                saveButton
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("正在启动播放器...")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // MARK: - 保存到文件

    private var saveButton: some View {
        Button {
            downloadAndSave()
        } label: {
            if downloading {
                HStack {
                    ProgressView().tint(.white)
                    Text("下载中...")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.35))
                .foregroundColor(.white)
                .cornerRadius(10)
            } else {
                Label("保存到文件", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
        .disabled(downloading)
    }

    // MARK: - 播放控制

    private func start() {
        guard let url = rawURL else { return }
        if file.isImage {
            loadImage(url: url)
        } else if file.isAudio {
            startNative(url: url, isAudio: true)
        } else if file.isVideo {
            if isNativePlayable {
                startNative(url: url, isAudio: false)
            } else {
                startVLC(target: url)
            }
        }
    }

    private func startNative(url: URL, isAudio: Bool) {
        guard let token = fb.token else { return }
        let headers = ["X-Auth": token]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        if isAudio {
            audioPlayer = p
        } else {
            avPlayer = p
        }
        p.play()
    }

    private func startVLC(target: URL) {
        guard let token = fb.token else { vlcError = true; return }
        // 经本地代理去掉认证，VLC 才能访问
        LocalProxyServer.shared.start()
        retryRegister(target: target, token: token, attempt: 0)
    }

    private func retryRegister(target: URL, token: String, attempt: Int) {
        if let local = LocalProxyServer.shared.register(targetURL: target, token: token) {
            guard let url = URL(string: local) else { vlcError = true; return }
            let p = VLCMediaPlayer()
            p.media = VLCMedia(url: url)
            vlcPlayer = p
            // VLCPlayerView makeUIView 时会设 drawable 并 play
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                vlcReady = true
            }
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                retryRegister(target: target, token: token, attempt: attempt + 1)
            }
        } else {
            vlcError = true
        }
    }

    private func stop() {
        avPlayer?.pause()
        avPlayer = nil
        audioPlayer?.pause()
        audioPlayer = nil
        vlcPlayer?.stop()
        vlcPlayer = nil
        vlcReady = false
        vlcError = false
        image = nil
        imageError = false
    }

    private func loadImage(url: URL) {
        guard let token = fb.token else { imageError = true; return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data, let img = UIImage(data: data) {
                    self.image = img
                } else {
                    self.imageError = true
                }
            }
        }.resume()
    }

    private func downloadAndSave() {
        guard let url = rawURL, let token = fb.token else {
            downloadError = "FileBrowser 未登录或地址错误"
            return
        }
        downloading = true
        downloadError = nil
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.downloadTask(with: req) { tempURL, _, err in
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
}

/// VLC 播放视图（UIViewRepresentable）：把 VLCMediaPlayer 渲染到 SwiftUI
struct VLCPlayerView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        if player.media != nil && !player.isPlaying {
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 系统分享面板（保存到文件 / 分享给第三方）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
