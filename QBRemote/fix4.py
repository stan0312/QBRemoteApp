import io
p = 'MediaPreviewView.swift'
s = io.open(p, encoding='utf-8').read()
block = '''

/// HTML5 播放视图（WKWebView 内嵌 <video>/<audio>，播放免认证分享链接）
/// iOS 的 WKWebView 播放 mp4/mov/m4v/mp3 等原生支持格式，控件自带全屏/进度/倍速
struct HTML5VideoView: UIViewRepresentable {
    let url: URL
    let isAudio: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        let src = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\\"", with: "%22")
        let tag = isAudio ? "audio" : "video"
        let html = \"\"\"
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
        body{display:flex;align-items:center;justify-content:center}
        video{width:100%;height:100%;object-fit:contain;background:#000}
        audio{width:92%}
        .err{color:#ccc;font-family:-apple-system,sans-serif;font-size:14px;text-align:center;padding:24px}
        </style></head><body>
        <\\(tag) id="m" controls autoplay playsinline webkit-playsinline src="\\(src)"></\\(tag)>
        <script>
        var m=document.getElementById('m');
        m.addEventListener('error',function(){
            document.body.innerHTML='<div class="err">无法播放，请用其他 App 打开</div>';
        });
        </script></body></html>
        \"\"\"
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
'''
s = s.rstrip() + block
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('APPENDED')
