import SwiftUI
import WebKit

struct ContentView: View {
    @State private var webView: WKWebView?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentURL: URL?
    @State private var showSettings = false
    @State private var startURL = UserDefaults.standard.string(forKey: "startURL") ?? "http://sdcs.asuscomm.com:8085/"

    var body: some View {
        VStack(spacing: 0) {
            WebView(
                urlString: startURL,
                webView: $webView,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                currentURL: $currentURL
            )
            .ignoresSafeArea(.container, edges: .top)

            Divider()

            bottomToolbar
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(startURL: $startURL) { newURL in
                var url = newURL
                if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
                    url = "http://" + url
                }
                startURL = url
                UserDefaults.standard.set(url, forKey: "startURL")
                if let u = URL(string: url) {
                    webView?.load(URLRequest(url: u))
                }
            }
        }
    }

    var bottomToolbar: some View {
        HStack {
            Button(action: { webView?.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Button(action: { webView?.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)

            Spacer()

            Button(action: { webView?.reload() }) {
                Image(systemName: "arrow.clockwise")
            }

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }

            Button(action: {
                if let url = currentURL ?? URL(string: startURL) {
                    UIApplication.shared.open(url)
                }
            }) {
                Image(systemName: "safari")
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.primary)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

// MARK: - WebView

struct WebView: UIViewRepresentable {
    let urlString: String
    @Binding var webView: WKWebView?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var currentURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 持久化登录 Cookie
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true // 侧滑前进/后退

        DispatchQueue.main.async {
            self.webView = wv
        }
        if let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView

        init(_ parent: WebView) {
            self.parent = parent
        }

        func syncState(_ webView: WKWebView) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            syncState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncState(webView)
        }

        // 处理 target=_blank / 新窗口：在同一 WebView 内打开
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Binding var startURL: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("qBittorrent Web UI 地址")) {
                    TextField("例如 http://sdcs.asuscomm.com:8085/", text: $startURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(footer: Text("地址会自动补全 http:// 前缀。登录状态会保存在本机，下次打开不用重新登录。")) {
                    EmptyView()
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(startURL)
                        dismiss()
                    }
                }
            }
        }
    }
}
