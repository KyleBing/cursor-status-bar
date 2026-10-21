import AppKit
import WebKit

// 内置登录窗口：在应用里直接打开 platform.deepseek.com 完成登录，
// 再从页面 localStorage 读出 userToken，连同 deepseek 域下的 cookie 一起回传。
// 这样就不用手工去 DevTools 复制 token，登录态过期后也能一键重新获取。
final class DeepSeekLoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = DeepSeekLoginWindow()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var pollTimer: Timer?
    // 拿到新 token 时回调；返回 false 表示凭证被平台拒绝，窗口继续留着让用户重新登录
    private var onToken: (@MainActor (String, String) async -> Bool)?
    // 已保存的旧 token：内容相同说明页面还没重新登录，不能当成新凭证
    private var staleToken = ""
    // 防止校验期间重复触发
    private var isValidating = false
    // 复用默认存储，登录态可以留到下次使用
    private let dataStore = WKWebsiteDataStore.default()
    private let loginURL = URL(string: "https://platform.deepseek.com/usage")!

    // 打开（或前置）登录窗口
    func present(
        previousToken: String,
        onToken: @escaping @MainActor (String, String) async -> Bool
    ) {
        self.onToken = onToken
        self.staleToken = previousToken
        isValidating = false

        if let window {
            showStatus(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            startPolling()
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // 底部留一条状态栏，token 被拒时能直接看到原因
        let container = NSView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        self.statusLabel = label

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "platform.deepseek.com"
        window.contentView = container
        window.delegate = self
        window.center()
        self.window = window

        // 菜单栏应用默认是 accessory，临时切成 regular 才能正常抢到焦点
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: loginURL))
        startPolling()
    }

    // MARK: - 轮询 token

    // 登录成功后 userToken 才写进 localStorage，这里定时读，取到新值才继续
    private func startPolling(interval: TimeInterval = 1.2) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.readToken()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func readToken() {
        guard let webView, !isValidating else { return }
        // 值可能是 {"value":"...","__version":"0"} 的 JSON 外壳，这里拆开只取 value
        let script = """
        (function () {
          try {
            var raw = localStorage.getItem('userToken') || '';
            var value = raw;
            try {
              var parsed = JSON.parse(raw);
              if (parsed && parsed.value) { value = parsed.value; }
            } catch (e) {}
            return value || '';
          } catch (e) { return ''; }
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let token = result as? String, !token.isEmpty else { return }
            // 还是旧 token 说明页面没重新登录，继续等；否则交给调用方校验
            guard token != self.staleToken else { return }
            self.verify(token)
        }
    }

    // 先校验再关窗：被平台拒绝时保持窗口打开，让用户在同一页面重新登录
    private func verify(_ token: String) {
        guard let onToken else { return }
        isValidating = true
        stopPolling()
        showStatus("Checking token…", color: .secondaryLabelColor)
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            // 只保留 deepseek 域的 cookie，拼成可直接放进请求头的形式
            let header = cookies
                .filter { $0.domain.contains("deepseek.com") }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            Task { @MainActor in
                let ok = await onToken(token, header)
                guard let self else { return }
                self.isValidating = false
                if ok {
                    self.onToken = nil
                    self.close()
                } else {
                    // 记下这个失效 token，避免对它反复发请求
                    self.staleToken = token
                    self.showStatus(
                        "This token was rejected. Sign in again, then the window closes by itself.",
                        color: .systemRed
                    )
                    // 放慢轮询：登录失败期间不该高频打平台接口
                    self.startPolling(interval: 5)
                }
            }
        }
    }

    private func showStatus(_ text: String?, color: NSColor = .secondaryLabelColor) {
        statusLabel?.stringValue = text ?? ""
        statusLabel?.textColor = color
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // 关窗并把激活策略还回菜单栏模式
    private func close() {
        stopPolling()
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        statusLabel = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - 代理

    // 用户手动关窗时视为取消，只清理资源
    func windowWillClose(_ notification: Notification) {
        onToken = nil
        stopPolling()
        window = nil
        webView = nil
        statusLabel = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // 页面加载完先试一次，已经登录的话可以立刻取到 token
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readToken()
    }
}
