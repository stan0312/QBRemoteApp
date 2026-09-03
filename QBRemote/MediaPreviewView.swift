import SwiftUI
import AVKit
import AVFoundation
import ImageIO
import MobileVLCKit
import WebKit

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
    @State private var showFullScreen = false
    @State private var htmlURL: URL?
    @State private var htmlReady = false
    @State private var htmlError = false
    @State private var htmlBusy = false
    @State private var downloadProgress: Double = 0
    @State private var isDownloading = false
    @State private var activeTasks: [URLSessionDataTask] = []
    @State private var largeFileTotal: Int64 = 0
    @State private var showLargeFileAlert = false

    private var rawURL: URL? {
        fb.rawURL(savePath: torrent.save_path, relativeName: file.name, prefix: settings.pathPrefix)
    }

    /// AVPlayer 是否原生支持该格式（MKV/AVI/WMV/FLV/WebM 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v", "3gp", "m4a"].contains(file.fileExtension)
    }

    /// HTML5（WKWebView <video>/<audio>）可播放的格式（iOS Safari 原生支持）
    private var isHtml5Playable: Bool {
        ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(file.fileExtension)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay(alignment: .bottomTrailing) {
            fullScreenButton
        }
        .onAppear { start() }
        .onDisappear { stop() }
        .fullScreenCover(isPresented: $showFullScreen) {
            if isNativePlayable, let p = avPlayer {
                NativeFullScreenPlayer(player: p)
            } else if let p = vlcPlayer, vlcReady {
                VLCFullScreenPlayer(player: p)
            }
        }
        .alert("文件较大", isPresented: $showLargeFileAlert) {
            Button("继续下载") {
                if let url = rawURL, let token = fb.token {
                    downloadSegments(url: url, token: token, total: largeFileTotal)
                }
            }
            Button("取消", role: .cancel) {
                cancelDownload()
            }
        } message: {
            Text("该文件约 \(ByteCountFormatter.string(fromByteCount: largeFileTotal, countStyle: .file))，下载完成后播放。继续吗？")
        }
    }

    /// 视频全屏按钮（图片/音频不显示）
    @ViewBuilder
    private var fullScreenButton: some View {
        if file.isVideo, (avPlayer != nil || vlcPlayer != nil) {
            Button {
                showFullScreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .padding(20)
        }
    }

    /// 下载进度界面（多连接满速下载中）
    @ViewBuilder
    private var downloadProgressContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text("正在满速下载，完成后自动播放…")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("多连接并发下载 · 已下载 \(Int(downloadProgress * 100))%")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
            Button {
                cancelDownload()
            } label: {
                Text("取消")
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if file.isImage {
            imageContent
        } else if isDownloading {
            downloadProgressContent
        } else if file.isVideo {
            if let p = avPlayer {
                VideoPlayer(player: p)
                    .ignoresSafeArea()
            } else if let p = vlcPlayer, vlcReady {
                VLCPlayerView(player: p)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)
                    Text("播放失败")
                        .foregroundColor(.white)
                }
            }
        } else if file.isAudio, audioPlayer != nil {
            audioContent
        } else {
            Color.black
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

    // MARK: - HTML5 播放（WKWebView <video>/<audio>，播放免认证分享链接）

    @ViewBuilder
    private var html5Content: some View {
        if let url = htmlURL, htmlReady {
            HTML5VideoView(url: url, isAudio: file.isAudio)
                .ignoresSafeArea()
        } else if htmlError {
            htmlErrorContent
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("正在生成播放链接...")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    /// HTML5 无法播放（格式不支持或生成链接失败）时的界面
    @ViewBuilder
    private var htmlErrorContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("无法用 HTML5 播放器播放 .\(file.fileExtension)")
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("iOS 的 HTML5 播放器不支持该格式，可生成免认证链接用 SenPlayer / VidHub / Safari 打开")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                openExternal()
            } label: {
                Label("用其他 App 打开（绕限速）", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            saveButton
        }
    }

    /// 创建 HTML5/MSE 播放的数据源并注册到本地代理
    /// v13：直接用带认证的 /api/raw（Range 已验证支持，图片多连接满速成功），
    /// 经本地代理多连接分段转发，供 MSE 播放器 JS fetch（同源），避免分享链接 Range 不确定
    private func createHtml5Share() {
        guard !htmlBusy else { return }
        guard let raw = rawURL else { DispatchQueue.main.async { self.htmlError = true }; return }
        guard let token = fb.token else {
            DispatchQueue.main.async { self.htmlError = true }
            return
        }
        htmlBusy = true
        LocalProxyServer.shared.start()
        retryRegisterForHtml(target: raw, token: token, attempt: 0)
    }

    private func retryRegisterForHtml(target: URL, token: String, attempt: Int) {
        if let local = LocalProxyServer.shared.register(targetURL: target, token: token),
           let url = URL(string: local) {
            DispatchQueue.main.async {
                self.htmlURL = url
                self.htmlReady = true
                self.htmlBusy = false
            }
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.retryRegisterForHtml(target: target, token: token, attempt: attempt + 1)
            }
        } else {
            DispatchQueue.main.async {
                self.htmlError = true
                self.htmlBusy = false
            }
        }
    }

    /// 注册免认证（分享链接）到本地代理，供 MSE 播放器使用
    private func registerProxyNoAuth(_ target: URL, completion: @escaping (URL) -> Void) {
        LocalProxyServer.shared.start()
        retryRegisterNoAuth(target: target, attempt: 0, completion: completion)
    }

    private func retryRegisterNoAuth(target: URL, attempt: Int, completion: @escaping (URL) -> Void) {
        if let local = LocalProxyServer.shared.register(targetURL: target, token: nil),
           let url = URL(string: local) {
            completion(url)
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.retryRegisterNoAuth(target: target, attempt: attempt + 1, completion: completion)
            }
        } else {
            DispatchQueue.main.async { self.htmlError = true }
        }
    }

    /// 生成分享链接并弹出分享面板（给 SenPlayer / VidHub / Safari 打开）
    private func openExternal() {
        guard fb.token != nil else { return }
        let rel = fb.fbRelativePath(savePath: torrent.save_path,
                                    relativeName: file.name,
                                    prefix: settings.pathPrefix)
        Task {
            do {
                if let share = try await fb.createShare(relativePath: rel, hours: 24),
                   let u = URL(string: share.url) {
                    self.localFileURL = u
                    self.showShare = true
                }
            } catch {}
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
        } else if file.isVideo || file.isAudio {
            // v14：iPhone（iOS 16.2）无 MSE，HTML5 流式方案不可用。
            // 改为多连接分段下载到本地，再交给 AVPlayer/VLC 播放：
            // 满速（绕单连接限速）、兼容所有格式、下载期间显示进度不再白屏。
            startSegmentDownload(url: url)
        } else {
            htmlError = true
        }
    }

    // MARK: - 多连接下载 + 本地播放（v14，iOS 16 无 MSE 的替代方案）

    private func startSegmentDownload(url: URL) {
        guard let token = fb.token else { htmlError = true; return }
        isDownloading = true
        downloadProgress = 0
        var probe = URLRequest(url: url)
        probe.setValue(token, forHTTPHeaderField: "X-Auth")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: probe) { [weak self] _, resp, _ in
            var total: Int64 = -1
            if let http = resp as? HTTPURLResponse, http.statusCode == 206,
               let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let last = cr.split(separator: "/").last, let t = Int64(last) {
                total = t
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if total <= 0 {
                    self.downloadSingle(url: url, token: token)
                } else if total > 500 * 1024 * 1024 {
                    self.largeFileTotal = total
                    self.showLargeFileAlert = true
                } else {
                    self.downloadSegments(url: url, token: token, total: total)
                }
            }
        }.resume()
    }

    private func downloadSegments(url: URL, token: String, total: Int64) {
        let parts = 8
        let segSize = (total + Int64(parts) - 1) / Int64(parts)
        var datas: [Int: Data] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for i in 0..<parts {
            let start = Int64(i) * segSize
            let end = min(start + segSize - 1, total - 1)
            guard start <= end else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Auth")
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let task = URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { group.leave() }
                if let data = data {
                    lock.lock(); datas[i] = data; lock.unlock()
                }
                DispatchQueue.main.async {
                    var done = 0
                    lock.lock(); done = datas.count; lock.unlock()
                    self.downloadProgress = min(1, Double(done) / Double(parts))
                }
            }
            activeTasks.append(task)
            task.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var merged = Data()
            var ok = true
            for i in 0..<parts {
                if let d = datas[i] { merged.append(d) } else { ok = false }
            }
            if !ok || merged.isEmpty {
                self.htmlError = true
                return
            }
            self.isDownloading = false
            self.writeAndPlay(data: merged)
        }
    }

    private func downloadSingle(url: URL, token: String) {
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.isDownloading = false
                    self.writeAndPlay(data: data)
                } else {
                    self.htmlError = true
                }
            }
        }
        activeTasks.append(task)
        task.resume()
    }

    private func writeAndPlay(data: Data) {
        let ext = file.fileExtension.isEmpty ? "mp4" : file.fileExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try data.write(to: dest)
            playLocal(fileURL: dest)
        } catch {
            htmlError = true
        }
    }

    private func playLocal(fileURL: URL) {
        if file.isAudio {
            let p = AVPlayer(url: fileURL)
            audioPlayer = p
            p.play()
        } else if isNativePlayable {
            let p = AVPlayer(url: fileURL)
            avPlayer = p
            p.play()
        } else {
            let p = VLCMediaPlayer()
            p.media = VLCMedia(url: fileURL)
            vlcPlayer = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.vlcReady = true
            }
        }
    }

    private func cancelDownload() {
        for t in activeTasks { t.cancel() }
        activeTasks.removeAll()
        isDownloading = false
    }

    private func startNative(url: URL, isAudio: Bool) {
        // 经本地代理（正确 MIME + Range），AVPlayer 才能稳定识别播放
        registerProxy(url) { localURL in
            let asset = AVURLAsset(url: localURL)
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            DispatchQueue.main.async {
                if isAudio {
                    self.audioPlayer = p
                } else {
                    self.avPlayer = p
                }
                p.play()
            }
        }
    }

    private func startVLC(target: URL) {
        registerProxy(target) { localURL in
            let p = VLCMediaPlayer()
            p.media = VLCMedia(url: localURL)
            self.vlcPlayer = p
            // VLCPlayerView makeUIView 时会设 drawable 并 play
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.vlcReady = true
            }
        }
    }

    /// 经本地代理注册文件，成功后回调本地 URL；代理未就绪时自动重试
    private func registerProxy(_ target: URL, completion: @escaping (URL) -> Void) {
        guard let token = fb.token else {
            DispatchQueue.main.async { self.vlcError = true }
            return
        }
        LocalProxyServer.shared.start()
        retryRegister(target: target, token: token, attempt: 0, completion: completion)
    }

    private func retryRegister(target: URL, token: String, attempt: Int, completion: @escaping (URL) -> Void) {
        if let local = LocalProxyServer.shared.register(targetURL: target, token: token),
           let url = URL(string: local) {
            completion(url)
        } else if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.retryRegister(target: target, token: token, attempt: attempt + 1, completion: completion)
            }
        } else {
            DispatchQueue.main.async { self.vlcError = true }
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
        htmlURL = nil
        htmlReady = false
        htmlError = false
        htmlBusy = false
    }

    private func loadImage(url: URL) {
        guard let token = fb.token else { imageError = true; return }
        // 先探测文件总大小（Range 请求拿 Content-Range），支持则走多连接并发下载（绕单连接限速）
        var probe = URLRequest(url: url)
        probe.setValue(token, forHTTPHeaderField: "X-Auth")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: probe) { _, resp, _ in
            var total: Int64 = -1
            if let http = resp as? HTTPURLResponse,
               http.statusCode == 206,
               let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let last = cr.split(separator: "/").last,
               let t = Int64(last) {
                total = t
            }
            if total <= 0 {
                DispatchQueue.main.async { self.loadImageSingle(url: url) }
            } else {
                self.downloadImageSegments(url: url, token: token, total: total)
            }
        }.resume()
    }

    /// 多连接并发下载图片并解码（分 4 段，按序合并，绕单连接限速）
    private func downloadImageSegments(url: URL, token: String, total: Int64) {
        let parts = 4
        let segSize = (total + Int64(parts) - 1) / Int64(parts)
        var datas: [Int: Data] = [:]
        var failed = false
        let lock = NSLock()
        let group = DispatchGroup()
        for i in 0..<parts {
            let start = Int64(i) * segSize
            let end = min(start + segSize - 1, total - 1)
            guard start <= end else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Auth")
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { group.leave() }
                if let data = data {
                    lock.lock(); datas[i] = data; lock.unlock()
                } else {
                    failed = true
                }
            }.resume()
        }
        group.notify(queue: .main) {
            if failed {
                self.loadImageSingle(url: url)
                return
            }
            var merged = Data()
            for i in 0..<parts {
                if let d = datas[i] { merged.append(d) }
            }
            if merged.isEmpty {
                self.imageError = true
            } else {
                self.decodeImage(data: merged)
            }
        }
    }

    /// 单连接整下（无 Range 支持或分段失败时回退）
    private func loadImageSingle(url: URL) {
        guard let token = fb.token else { imageError = true; return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data {
                    self.decodeImage(data: data)
                } else {
                    self.imageError = true
                }
            }
        }.resume()
    }

    /// 解码图片（gif 动图 / 静态图）
    private func decodeImage(data: Data) {
        if self.file.fileExtension == "gif", let gif = Self.animatedImage(from: data) {
            self.image = gif
        } else if let img = UIImage(data: data) {
            self.image = img
        } else {
            self.imageError = true
        }
    }

    /// GIF 动图解码（ImageIO 逐帧合成动画 UIImage）
    private static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var images: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            if let cg = CGImageSourceCreateImageAtIndex(source, i, nil) {
                images.append(UIImage(cgImage: cg))
            }
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let d = gif[kCGImagePropertyGIFDelayTime] as? Double {
                duration += d
            } else {
                duration += 0.1
            }
        }
        return UIImage.animatedImage(with: images, duration: max(duration, 0.01))
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

/// 原生视频全屏播放器：系统 AVPlayerViewController，自带全部播放器功能
/// （进度、音量、倍速、画中画、横屏全屏等）
struct NativeFullScreenPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        vc.entersFullScreenWhenPlaybackBegins = false
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

/// MKV 等非原生视频全屏播放器：VLC + 自定义控制条
/// （播放/暂停、进度拖动、倍速、退出全屏）
struct VLCFullScreenPlayer: View {
    let player: VLCMediaPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var position: Double = 0
    @State private var curText = "00:00:00"
    @State private var durText = "00:00:00"
    @State private var isPlaying = false
    @State private var rate: Float = 1.0
    @State private var seeking = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCPlayerView(player: player)
                .ignoresSafeArea()

            // 控制层
            VStack {
                HStack {
                    Text("全屏播放")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()

                // 底部控制条
                VStack(spacing: 10) {
                    Slider(value: $position, in: 0...1) { editing in
                        if editing {
                            seeking = true
                        } else {
                            player.position = Float(position)
                            seeking = false
                            if isPlaying { player.play() }
                        }
                    }
                    .tint(.white)

                    HStack {
                        Text(curText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Text(durText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }

                    HStack(spacing: 40) {
                        // 倍速
                        Menu {
                            ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                                Button {
                                    rate = Float(r)
                                    player.rate = Float(r)
                                } label: {
                                    if rate == Float(r) {
                                        Label("\(formatRate(Float(r)))x", systemImage: "checkmark")
                                    } else {
                                        Text("\(formatRate(Float(r)))x")
                                    }
                                }
                            }
                        } label: {
                            Text("\(formatRate(rate))x")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }

                        // 播放/暂停
                        Button {
                            if player.isPlaying {
                                player.pause()
                                isPlaying = false
                            } else {
                                player.play()
                                isPlaying = true
                            }
                        } label: {
                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 54))
                                .foregroundColor(.white)
                        }

                        // 退出全屏
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }
                    .foregroundColor(.white)
                }
                .padding(.horizontal)
                .padding(.bottom, 18)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .onAppear {
            player.play()
            isPlaying = true
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if !seeking {
                position = Double(player.position)
            }
            let cur = player.time.intValue
            let len = player.media?.length.intValue ?? 0
            curText = formatTime(Int(cur / 1000))
            if len > 0 {
                durText = formatTime(Int(len / 1000))
            }
            isPlaying = player.isPlaying
        }
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func formatRate(_ r: Float) -> String {
        r == Float(Int(r)) ? "\(Int(r))" : String(format: "%.2g", r)
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

/// HTML5 播放视图（WKWebView 内嵌 player.html）
/// v12：加载 bundle 内的 player.html（mp4box + MSE 多连接分片），用 JS fetch 多连接 Range 拉本地代理
struct HTML5VideoView: UIViewRepresentable {
    let url: URL
    let isAudio: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, isAudio: isAudio)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        // 同源加载 MSE 播放器页面（本地代理提供 player.html + mp4box），避免 file:// fetch 限制
        if let base = LocalProxyServer.shared.baseURL, let url = URL(string: base + "player.html") {
            webView.load(URLRequest(url: url))
        } else if let file = Bundle.main.url(forResource: "player.html", withExtension: nil) {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.url = url
        context.coordinator.isAudio = isAudio
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var url: URL
        var isAudio: Bool
        init(url: URL, isAudio: Bool) {
            self.url = url
            self.isAudio = isAudio
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let src = url.absoluteString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let js = "window.startPlayback(\"\(src)\", \(isAudio));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
