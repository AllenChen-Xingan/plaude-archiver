import AppKit
import WebKit

// Shows web.plaud.ai in a window and watches the cookie jar for the `pld_ut` (UT) token.
// Nothing is scraped from the page; we only read the cookie the site sets after you log in.
@MainActor
final class LoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var done = false
    private let onToken: (String) -> Void
    var onClose: () -> Void = {}   // called if the user closes the window without signing in

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        super.init()
    }

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent: a prior login is remembered
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView = web

        let win = NSWindow(contentRect: web.frame,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Sign in to Plaud"
        win.contentView = web
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        NSApp.setActivationPolicy(.regular)   // temporarily show in Dock so the window can focus
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "https://web.plaud.ai/")!))

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCookies() }
        }
    }

    private func checkCookies() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            if let ut = cookies.first(where: { $0.name == "pld_ut" && !$0.value.isEmpty }) {
                self.finish(token: ut.value)
            }
        }
    }

    private func finish(token: String) {
        guard !done else { return }
        done = true
        cleanup()
        onToken(token)
    }

    // The user closed the sign-in window before a token appeared.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.cancel() }
    }

    private func cancel() {
        guard !done else { return }   // finish() already handled it
        done = true
        cleanup()
        onClose()
    }

    private func cleanup() {
        timer?.invalidate(); timer = nil
        window?.delegate = nil
        window?.close()
        window = nil; webView = nil
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.checkCookies() }
    }
}
