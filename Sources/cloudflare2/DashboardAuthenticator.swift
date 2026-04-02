import AppKit
import Foundation
import WebKit

@MainActor
final class DashboardAuthenticator: NSObject {
    private var completion: ((Result<DashboardSession, Error>) -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadingOverlay: NSVisualEffectView?
    private var loadingIndicator: NSProgressIndicator?
    private var xAtok: String?
    private var hasBootstrapUser = false
    private var cookies: [HTTPCookie] = []
    private var pollTimer: Timer?
    private var isFinishing = false

    func present(accountID: String, completion: @escaping (Result<DashboardSession, Error>) -> Void) {
        self.completion = completion
        showLoginWindow(accountID: accountID)
    }

    private func showLoginWindow(accountID: String) {
        let userContentController = WKUserContentController()

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .nonPersistent()

        let frame = NSRect(x: 0, y: 0, width: 540, height: 760)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloudflare Login"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.delegate = self

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        container.addSubview(webView)
        let loadingOverlay = makeLoadingOverlay()
        container.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            loadingOverlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            loadingOverlay.widthAnchor.constraint(equalToConstant: 120),
            loadingOverlay.heightAnchor.constraint(equalToConstant: 36),
        ])
        self.loadingOverlay = loadingOverlay
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window

        let url = URL(string: "https://dash.cloudflare.com/login")!
        var request = URLRequest(url: url)
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        setLoading(true)
        webView.load(request)
        startPolling()
    }

    private func makeLoadingOverlay() -> NSVisualEffectView {
        let overlay = NSVisualEffectView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.blendingMode = .withinWindow
        overlay.material = .menu
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 4

        let indicator = NSProgressIndicator(frame: .zero)
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        overlay.addSubview(indicator)
        self.loadingIndicator = indicator

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        return overlay
    }

    private func setLoading(_ isLoading: Bool) {
        loadingOverlay?.isHidden = !isLoading
        if isLoading {
            loadingIndicator?.startAnimation(nil)
        } else {
            loadingIndicator?.stopAnimation(nil)
        }
    }

    private func refreshCookies() {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.cookies = cookies.filter { $0.domain.contains("cloudflare.com") }
                self?.finishIfReady()
            }
        }
    }

    private func tryExtractAtokFromPage() {
        let script = """
        (() => {
          const raw = window.localStorage.getItem("bootstrap-cache");
          if (!raw) return null;
          try {
            const parsed = JSON.parse(raw);
            return {
              atok: typeof parsed?.atok === "string" ? parsed.atok : null,
              securityToken: typeof parsed?.data?.security_token === "string" ? parsed.data.security_token : null,
              userID: typeof parsed?.data?.user?.id === "string" ? parsed.data.user.id : null
            };
          } catch (_) {
            return null;
          }
        })();
        """

        webView?.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                if let payload = value as? [String: Any] {
                    if let atok = payload["atok"] as? String, !atok.isEmpty {
                        self?.xAtok = atok
                    }
                    let userID = payload["userID"] as? String
                    let securityToken = payload["securityToken"] as? String
                    self?.hasBootstrapUser = !(userID?.isEmpty ?? true) && !(securityToken?.isEmpty ?? true)
                }
                self?.finishIfReady()
            }
        }
    }

    private func finishIfReady() {
        guard let xAtok, !xAtok.isEmpty else {
            return
        }
        guard hasBootstrapUser else {
            return
        }
        if let currentURL = webView?.url, currentURL.path == "/login" {
            return
        }
        let usefulCookies = cookies.filter { cookie in
            cookie.name == "__cf_logged_in" || cookie.name == "vses2" || cookie.name == "cf_clearance"
        }
        guard !usefulCookies.isEmpty else {
            return
        }

        let session = DashboardSession(
            capturedAt: Date(),
            xAtok: xAtok,
            cookies: cookies.map(DashboardCookie.init(cookie:))
        )

        do {
            try DashboardSessionStore.save(session)
            finish(.success(session))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<DashboardSession, Error>) {
        guard !isFinishing else {
            return
        }
        isFinishing = true
        pollTimer?.invalidate()
        pollTimer = nil
        let callback = completion
        completion = nil
        let webView = webView
        let window = window

        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.contentView = NSView(frame: .zero)
        window?.orderOut(nil)
        self.window = nil
        self.webView = nil
        loadingOverlay = nil
        loadingIndicator = nil
        xAtok = nil
        hasBootstrapUser = false
        cookies = []
        callback?(result)
        DispatchQueue.main.async {
            _ = webView
            _ = window
        }
        isFinishing = false
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCookies()
                self?.tryExtractAtokFromPage()
            }
        }
    }

    private static let acceptLanguage = "en-US,en;q=0.9"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
}

extension DashboardAuthenticator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        setLoading(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setLoading(false)
        refreshCookies()
        tryExtractAtokFromPage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setLoading(false)
        finish(.failure(DashboardError.loginFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        setLoading(false)
        finish(.failure(DashboardError.loginFailed(error.localizedDescription)))
    }
}

extension DashboardAuthenticator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if completion != nil {
            finish(.failure(DashboardError.userCancelledLogin))
        }
    }
}
