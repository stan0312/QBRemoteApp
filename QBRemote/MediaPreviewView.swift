import SwiftUI
import AVKit
import AVFoundation
import ImageIO
import MobileVLCKit
import WebKit

/// 预览页全局播放控制命令（由右上角设置下发）
enum PreviewControl: Equatable {
    case none
    case pauseAll
    case playAll
}

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
    /// 预览页右上角「设置」入口（含播放控制、速度、调试日志、连接设置）
    @State private var showSettings = false
    /// 全局播放控制命令（暂停全部/开始全部）
    @State private var controlCmd: PreviewControl = .none
    /// 全局播放速度
    @State private var playbackRate: Float = 1.0

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
                                  downloadError: $downloadError,
                                  controlCmd: controlCmd,
                                  playbackRate: playbackRate)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear {
            Log("Preview", "进入预览页 共 \(files.count) 个文件 当前=\(currentIndex + 1)")
        }
        // 全屏预览也支持「左缘右滑」退出（与点右上角 xmark 等效）
        .edgeSwipeDismiss {
            dismiss()
        }
        .overlay(alignment: .topLeading) {
            // 明确的「返回」按钮兜底：手势万一失效也能一键退出预览
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .padding(.leading, 4)
                    .padding(.top, 4)
            }
            .accessibilityLabel("返回")
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                // 设置入口：连接设置 + 调试日志（不退出预览即可查看/修改）
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(14)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(12)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            PreviewSettingsSheet(settings: settings,
                                 controlCmd: $controlCmd,
                                 playbackRate: $playbackRate)
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
    /// 来自预览页设置下发的全局播放控制命令
    let controlCmd: PreviewControl
    /// 来自预览页设置的全局播放速度
    let playbackRate: Float

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
    /// 单连接整下兜底模式（远程链路不支持 Range 时），用于进度文案区分
    @State private var singleFallback = false
    @State private var isDownloading = false
    @State private var activeTasks: [URLSessionDataTask] = []
    /// 边下边播的本地临时文件（onDisappear 时删除）
    @State private var streamFileURL: URL?
    /// 边下边播失败诊断信息（连接不上/0 进度超时等）
    @State private var streamError: String?

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
        // 右上角设置下发的全局播放控制
        .onChange(of: controlCmd) { cmd in
            switch cmd {
            case .pauseAll:
                avPlayer?.pause()
                audioPlayer?.pause()
                vlcPlayer?.pause()
            case .playAll:
                avPlayer?.play()
                audioPlayer?.play()
                vlcPlayer?.play()
            case .none:
                break
            }
        }
        // 右上角设置下发的全局播放速度
        .onChange(of: playbackRate) { r in
            avPlayer?.rate = r
            audioPlayer?.rate = r
            vlcPlayer?.rate = r
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            ZStack(alignment: .topTrailing) {
                if isNativePlayable, let p = avPlayer {
                    NativeFullScreenPlayer(player: p)
                } else if let p = vlcPlayer, vlcReady {
                    VLCFullScreenPlayer(player: p)
                } else {
                    Color.black.ignoresSafeArea()
                }
                // 显式关闭按钮：修复「全屏后快进快退正常但退不出来」的问题
                Button {
                    showFullScreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(12)
                }
            }
            .ignoresSafeArea()
            .edgeSwipeDismiss { showFullScreen = false }
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
            Text("正在准备播放…")
                .font(.subheadline)
                .foregroundColor(.white)
            Text(singleFallback ? "单连接下载中 · 不支持分段加速" : "多连接并发 · 已缓冲 \(Int(downloadProgress * 100))%")
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

    /// 边下边播：播放器下方的缓冲进度小条
    @ViewBuilder
    private var progressOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("边下边播 · 已缓冲 \(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
            .cornerRadius(8)
            .padding(.bottom, 12)
        }
    }

    /// 错误提示
    @ViewBuilder
    private func errorContent(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(msg)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var content: some View {
        if file.isImage {
            imageContent
        } else if file.isVideo {
            // 边下边播：播放器一旦就绪立即显示，下载进度作为底部小条叠加（不再挡住播放画面）
            if let p = avPlayer {
                ZStack {
                    VideoPlayer(player: p)
                        .ignoresSafeArea()
                    if isDownloading { progressOverlay }
                }
            } else if let p = vlcPlayer, vlcReady {
                ZStack {
                    VLCPlayerView(player: p)
                        .ignoresSafeArea()
                    if isDownloading { progressOverlay }
                }
            } else if let err = streamError {
                errorContent(err)
            } else if isDownloading {
                downloadProgressContent
            } else {
                errorContent("播放失败")
            }
        } else if file.isAudio {
            if let p = audioPlayer {
                ZStack {
                    audioContent
                    if isDownloading { progressOverlay }
                }
            } else if let err = streamError {
                errorContent(err)
            } else if isDownloading {
                downloadProgressContent
            } else {
                Color.black
            }
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
        guard let url = rawURL else {
            Log("Preview", "无法生成远程 URL：save_path=\(torrent.save_path) name=\(file.name) prefix=\(settings.pathPrefix)")
            return
        }
        Log("Preview", "打开文件「\(file.name)」扩展名=\(file.fileExtension) 类型=\(file.isImage ? "图片" : (file.isVideo ? "视频" : (file.isAudio ? "音频" : "其他")))")
        Log("Preview", "远程 URL=\(url.absoluteString)")
        if file.isImage {
            loadImage(url: url)
        } else if file.isVideo || file.isAudio {
            // v15：iPhone（iOS 16.2）无 MSE。改为「边下边播」：
            // 多连接并发下载直接写入本地临时文件，同时本地代理从正在填充的文件
            // 按需供给 AVPlayer/VLC —— 点开即播、后台满速下载、兼容所有格式。
            startStreamingDownload(url: url)
        } else {
            Log("Preview", "不支持的文件类型，显示错误")
            htmlError = true
        }
    }

    // MARK: - 边下边播（v15，iOS 16 无 MSE 的替代方案）

    private func startStreamingDownload(url: URL) {
        guard let token = fb.token else { streamError = "FileBrowser 未登录，请返回重连"; return }
        isDownloading = true
        downloadProgress = 0
        singleFallback = false
        // 依次尝试候选 URL（自动映射失败(404)时用相对名直连兜底）
        probeStreaming(candidates: probeCandidates, index: 0, token: token)
    }

    /// 视频探针候选列表：①自动/手动映射 URL；②相对名直连（不套 save_path 顶层目录）
    private var probeCandidates: [URL] {
        var list: [URL] = []
        if let u = rawURL { list.append(u) }
        if let u = fb.rawURLDirect(relativeName: file.name), !list.contains(u) { list.append(u) }
        return list
    }

    /// 逐个候选探针：206 → 8 段并发；200 → 单连接整下；404/401/无响应 → 试下一个候选
    private func probeStreaming(candidates: [URL], index: Int, token: String) {
        guard index < candidates.count else {
            Log("Preview", "全部候选 URL 探针均失败（共 \(candidates.count) 个） → 报错")
            self.isDownloading = false
            self.streamError = "无法连接 FileBrowser 或文件路径不匹配。\n已尝试 \(candidates.count) 个地址均失败，请检查设置里的连接地址与路径映射，或查看调试日志。"
            return
        }
        let url = candidates[index]
        Log("Preview", "视频探针[候选\(index + 1)/\(candidates.count)]: \(url.absoluteString)")
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 10
        probe.setValue(token, forHTTPHeaderField: "X-Auth")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: probe) { _, resp, err in
            DispatchQueue.main.async {
                guard let http = resp as? HTTPURLResponse else {
                    // 请求级失败：地址不可达 / 端口未开放 / 网络错误
                    Log("Preview", "候选\(index + 1) 探针无 HTTP 响应 err=\(err?.localizedDescription ?? "未知") → 试下一候选")
                    self.probeStreaming(candidates: candidates, index: index + 1, token: token)
                    return
                }
                if http.statusCode == 206,
                   let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let last = cr.split(separator: "/").last, let t = Int64(last), t > 0 {
                    // 正常支持 Range → 8 段并发边下边播
                    Log("Preview", "候选\(index + 1) 探针 206 支持 Range, Content-Range=\(cr) total=\(t) → 8 段并发")
                    self.startStreaming(url: url, token: token, total: t)
                } else if http.statusCode == 200 {
                    // 服务器忽略了 Range 请求、整返文件 → 单连接整下兜底
                    Log("Preview", "候选\(index + 1) 探针返回 200(忽略 Range) → 单连接整下兜底")
                    self.downloadStreamSingle(url: url, token: token)
                } else if http.statusCode == 401 || http.statusCode == 404 {
                    // 路径映射或权限问题 → 换下一个候选 URL 再试
                    Log("Preview", "候选\(index + 1) 探针返回 HTTP \(http.statusCode) → 试下一候选")
                    self.probeStreaming(candidates: candidates, index: index + 1, token: token)
                } else {
                    Log("Preview", "候选\(index + 1) 探针返回 HTTP \(http.statusCode) → 报错")
                    self.isDownloading = false
                    self.streamError = "FileBrowser 返回错误（HTTP \(http.statusCode)）。\n请检查文件是否存在、账号是否有权限，或端口是否正确。"
                }
            }
        }.resume()
    }

    private func startStreaming(url: URL, token: String, total: Int64) {
        let ext = file.fileExtension.isEmpty ? "mp4" : file.fileExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        streamFileURL = fileURL
        let written = StreamWritten()
        Log("Preview", "8 段并发开始 total=\(total) 临时文件=\(fileURL.lastPathComponent)")
        guard let localURLString = LocalProxyServer.shared.registerLocalFile(fileURL: fileURL, total: total, written: written),
              let localURL = URL(string: localURLString) else {
            Log("Preview", "本地代理注册失败 → 报错")
            streamError = "本地代理未就绪，请重试"
            return
        }
        // 多连接并发下载，段 0（头部）与最后一段（尾部）优先，保证 moov 无论位置都能快速就绪
        let parts = 8
        let segSize = (total + Int64(parts) - 1) / Int64(parts)
        var order: [Int] = []
        if parts > 1 { order.append(0); order.append(parts - 1) }
        for i in 0..<parts where i != 0 && i != parts - 1 { order.append(i) }
        let group = DispatchGroup()
        let writeQueue = DispatchQueue(label: "qb.stream.write")
        let lock = NSLock()
        var completed = 0
        // 严格校验每段：必须 206 且 Content-Range 覆盖请求区间、字节数等于区间长度；
        // 否则说明远程链路忽略/不支持 Range（返回 200 整文件），整段拼接会损坏文件 → 立即降级单连接整下
        var segFailed = 0
        for idx in order {
            let s = Int64(idx) * segSize
            let e = min(s + segSize - 1, total - 1)
            guard s <= e else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-Auth")
            req.setValue("bytes=\(s)-\(e)", forHTTPHeaderField: "Range")
            let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let dataLen = Int64(data?.count ?? 0)
                let expected = e - s + 1
                if code == 206 && dataLen == expected, let data = data {
                    writeQueue.async {
                        if let fh = try? FileHandle(forWritingTo: fileURL) {
                            try? fh.seek(toOffset: UInt64(s))
                            try? fh.write(contentsOf: data)
                            try? fh.close()
                            written.set(e + 1)
                        }
                        lock.lock(); completed += 1; lock.unlock()
                        DispatchQueue.main.async {
                            self.downloadProgress = min(1, Double(completed) / Double(parts))
                        }
                        group.leave()
                    }
                } else {
                    // 段异常：不写入（避免把整文件×8 拼坏），计入失败
                    Log("Preview", "分段[\(s)-\(e)] 异常 HTTP=\(code) 数据长=\(dataLen) 期望=\(expected) → 计入失败")
                    lock.lock(); completed += 1; segFailed += 1; lock.unlock()
                    DispatchQueue.main.async {
                        self.downloadProgress = min(1, Double(completed) / Double(parts))
                    }
                    group.leave()
                }
            }
            activeTasks.append(task)
            task.resume()
        }
        group.notify(queue: .main) {
            if segFailed > 0 {
                Log("Preview", "\(segFailed) 段请求异常 → 降级单连接整下（远程链路可能不支持 Range）")
                self.cancelDownload()
                self.downloadStreamSingle(url: url, token: token)
                return
            }
            self.isDownloading = false
            written.set(total)
        }
        // 诊断：6 秒内 0 进度 → 判定连不上 FileBrowser，给出明确错误而非永远卡 0%
        // 单连接兜底有自己的 20 秒诊断，这里跳过避免误报
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.isDownloading && self.downloadProgress <= 0 && self.streamError == nil && !self.singleFallback {
                Log("Preview", "6 秒内 0 进度 → 触发超时诊断，取消下载")
                self.cancelDownload()
                self.streamError = "无法连接 FileBrowser 下载数据（6 秒内 0 进度）。\n请检查设置里的 FileBrowser 地址，或局域网开关填写的内网 IP 是否正确。"
            }
        }
        // 立即开始播放（秒开：本地代理从已下载部分按需供给）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.file.isAudio {
                let p = AVPlayer(url: localURL)
                self.audioPlayer = p
                p.play()
            } else if self.isNativePlayable {
                let p = AVPlayer(url: localURL)
                self.avPlayer = p
                p.play()
            } else {
                let p = VLCMediaPlayer()
                p.media = VLCMedia(url: localURL)
                self.vlcPlayer = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.vlcReady = true
                }
            }
        }
    }

    private func downloadStreamSingle(url: URL, token: String) {
        // 远程链路不支持 Range（探针返回 200 整返）时的兜底：单连接整下到临时文件再播。
        // 增加超时诊断：20 秒未完成且无错误时给出明确提示，避免一直转圈。
        singleFallback = true
        isDownloading = true
        downloadProgress = 0
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let data = data, !data.isEmpty {
                    Log("Preview", "单连接整下完成 字节=\(data.count)")
                    let ext = self.file.fileExtension.isEmpty ? "mp4" : self.file.fileExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + ext)
                    try? data.write(to: dest)
                    self.streamFileURL = dest
                    self.isDownloading = false
                    self.playLocal(fileURL: dest)
                } else {
                    Log("Preview", "单连接整下失败 err=\(err?.localizedDescription ?? "空数据/未知")")
                    self.isDownloading = false
                    self.streamError = "文件下载失败：\(err?.localizedDescription ?? "请检查 FileBrowser 地址与端口")"
                }
            }
        }
        activeTasks.append(task)
        task.resume()
        // 诊断：20 秒未完成且无错误 → 远程链路慢/异常，给出可操作提示
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if self.isDownloading && self.streamError == nil {
                Log("Preview", "单连接整下 20 秒未完成 → 触发超时诊断")
                self.cancelDownload()
                self.streamError = "远程下载超时（20 秒）。\n该视频的下载地址不支持分段加速，请检查 FileBrowser 的 8033 端口是否已对外开放，或改用局域网地址。"
            }
        }
    }

    private func playLocal(fileURL: URL) {
        Log("Preview", "开始本地播放 文件=\(fileURL.lastPathComponent) 类型=\(file.isAudio ? "音频" : (isNativePlayable ? "AVPlayer 原生" : "VLC"))")
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
        streamError = nil
        cancelDownload()
        if let url = streamFileURL {
            try? FileManager.default.removeItem(at: url)
            streamFileURL = nil
        }
    }

    private func loadImage(url: URL) {
        guard let token = fb.token else { imageError = true; return }
        // 依次尝试候选 URL（自动映射失败(404)时用相对名直连兜底）
        probeImage(candidates: probeCandidates, index: 0, token: token)
    }

    /// 逐个候选图片探测：206 且有 Content-Range → 分段并发；否则单连接整下
    private func probeImage(candidates: [URL], index: Int, token: String) {
        guard index < candidates.count else {
            Log("Preview", "图片全部候选 URL 探测失败（共 \(candidates.count) 个） → 报错")
            imageError = true
            return
        }
        let url = candidates[index]
        Log("Preview", "图片探测[候选\(index + 1)/\(candidates.count)]: \(url.absoluteString)")
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 10
        probe.setValue(token, forHTTPHeaderField: "X-Auth")
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: probe) { _, resp, err in
            var total: Int64 = -1
            var code = 0
            var range = ""
            if let http = resp as? HTTPURLResponse {
                code = http.statusCode
                range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                if http.statusCode == 206,
                   let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let last = cr.split(separator: "/").last,
                   let t = Int64(last) {
                    total = t
                }
            }
            DispatchQueue.main.async {
                Log("Preview", "图片探针[候选\(index + 1)] 结果 HTTP=\(code) Content-Range=\(range) total=\(total) err=\(err?.localizedDescription ?? "无")")
                if total <= 0 && (code == 401 || code == 404 || code == 0) {
                    Log("Preview", "图片候选\(index + 1) 失败(HTTP \(code)) → 试下一候选")
                    self.probeImage(candidates: candidates, index: index + 1, token: token)
                } else if total <= 0 {
                    Log("Preview", "图片候选\(index + 1) 不支持 Range(或请求失败) → 单连接整下")
                    self.loadImageSingle(url: url)
                } else {
                    self.downloadImageSegments(url: url, token: token, total: total)
                }
            }
        }.resume()
    }

    /// 多连接并发下载图片并解码（分 4 段，按序合并，绕单连接限速）
    /// 远程链路（DDNS 反代/运营商网关）可能不支持或忽略 Range：每段必须严格校验
    /// 返回 206 且 Content-Range 与请求区间一致，否则整段回退单连接下载，
    /// 避免把「整文件 × 4」拼坏导致解码失败。
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
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                defer { group.leave() }
                // 校验：必须是 206，且 Content-Range 覆盖请求区间，且数据长度 == 区间长度
                if let http = resp as? HTTPURLResponse, http.statusCode == 206,
                   let data = data,
                   let cr = http.value(forHTTPHeaderField: "Content-Range") {
                    // Content-Range 形如 "bytes start-end/total"，解析 start-end 段
                    let rangePart = cr.split(separator: " ").last ?? ""
                    let bounds = rangePart.split(separator: "/").first ?? ""
                    let se = bounds.split(separator: "-")
                    if se.count == 2,
                       let s = Int64(se[0]), let e = Int64(se[1]),
                       s == start, e == end, data.count == Int(e - s + 1) {
                        lock.lock(); datas[i] = data; lock.unlock()
                        return
                    }
                    Log("Preview", "图片段 \(i) 区间校验不符: HTTP=\(http.statusCode) CR=\(cr) 请求=[\(start)-\(end)] 收到字节=\(data.count)")
                } else {
                    Log("Preview", "图片段 \(i) 非 206 响应(HTTP=\((resp as? HTTPURLResponse)?.statusCode ?? 0)) → 回退单连接")
                }
                // 任何一段不是标准的 206 区间响应 → 放弃分段，回退单连接
                failed = true
            }.resume()
        }
        group.notify(queue: .main) {
            if failed {
                Log("Preview", "图片分段下载失败 → 回退单连接整下")
                self.loadImageSingle(url: url)
                return
            }
            var merged = Data()
            for i in 0..<parts {
                if let d = datas[i] { merged.append(d) }
            }
            Log("Preview", "图片 4 段合并完成 字节=\(merged.count)")
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
        Log("Preview", "图片单连接整下开始")
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Auth")
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let data = data {
                    Log("Preview", "图片单连接完成 字节=\(data.count)")
                    self.decodeImage(data: data)
                } else {
                    Log("Preview", "图片单连接失败 err=\(err?.localizedDescription ?? "空数据/未知")")
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
            Log("Preview", "图片解码失败(字节=\(data.count) 扩展名=\(self.file.fileExtension)) → 显示错误")
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
