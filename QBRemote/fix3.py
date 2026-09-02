import io
p = 'MediaPreviewView.swift'
s = io.open(p, encoding='utf-8').read()
def rep(old, new, label):
    global s
    if old in s:
        s = s.replace(old, new, 1)
        print('OK  :', label)
    else:
        print('FAIL:', label)
        # 提示附近
        import re
        head = old.split('\n')[0].strip()[:50]
        idx = s.find(head)
        print('      head found at', idx if idx>=0 else -1)

# 1. import WebKit
rep('''import AVKit
import AVFoundation
import ImageIO
import MobileVLCKit''',
'''import AVKit
import AVFoundation
import ImageIO
import MobileVLCKit
import WebKit''', 'import WebKit')

# 2. 属性
rep('''    @State private var showFullScreen = false
''',
'''    @State private var showFullScreen = false
    @State private var htmlURL: URL?
    @State private var htmlReady = false
    @State private var htmlError = false
    @State private var htmlBusy = false
''', 'html states')

# 3. isHtml5Playable
rep('''    /// AVPlayer 是否原生支持该格式（MKV/AVI/WMV/FLV/WebM 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v", "3gp", "m4a"].contains(file.fileExtension)
    }
''',
'''    /// AVPlayer 是否原生支持该格式（MKV/AVI/WMV/FLV/WebM 等不支持）
    private var isNativePlayable: Bool {
        !file.isVideo || ["mp4", "mov", "m4v", "3gp", "m4a"].contains(file.fileExtension)
    }

    /// HTML5（WKWebView <video>/<audio>）可播放的格式（iOS Safari 原生支持）
    private var isHtml5Playable: Bool {
        ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(file.fileExtension)
    }
''', 'isHtml5Playable')

# 4. content
rep('''    @ViewBuilder
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
''',
'''    @ViewBuilder
    private var content: some View {
        if file.isImage {
            imageContent
        } else if isHtml5Playable {
            html5Content
        } else if file.isVideo {
            htmlErrorContent
        }
    }
''', 'content')

# 5. start()
rep('''    private func start() {
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
''',
'''    private func start() {
        guard let url = rawURL else { return }
        if file.isImage {
            loadImage(url: url)
        } else if isHtml5Playable {
            createHtml5Share()
        } else {
            // iOS 的 HTML5 播放器不支持 mkv/avi/wmv/flv/webm 等格式
            htmlError = true
        }
    }
''', 'start')

# 6. html5 视图 + 错误视图 + 分享生成（插在 audioContent 前）
rep('''    // MARK: - 音频

    @ViewBuilder
    private var audioContent: some View {''',
'''    // MARK: - HTML5 播放（WKWebView <video>/<audio>，播放免认证分享链接）

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

    /// 创建免认证分享链接用于 HTML5 播放
    private func createHtml5Share() {
        guard !htmlBusy else { return }
        guard fb.token != nil else { htmlError = true; return }
        htmlBusy = true
        let rel = fb.fbRelativePath(savePath: torrent.save_path,
                                    relativeName: file.name,
                                    prefix: settings.pathPrefix)
        Task {
            do {
                if let share = try await fb.createShare(relativePath: rel, hours: 24),
                   let u = URL(string: share.url) {
                    self.htmlURL = u
                    self.htmlReady = true
                } else {
                    self.htmlError = true
                }
            } catch {
                self.htmlError = true
            }
            self.htmlBusy = false
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
    private var audioContent: some View {''', 'html5 content block')

# 7. stop() 重置
rep('''    private func stop() {
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
    }''',
'''    private func stop() {
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
    }''', 'stop reset')

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('DONE')
