import AppKit
import Foundation
import WebKit

@MainActor
final class DashboardAuthenticator: NSObject {
    private var completion: ((Result<DashboardSession, Error>) -> Void)?
    private var window: NSWindow?
    private weak var parentWindow: NSWindow?
    private var webView: WKWebView?
    private var cancelButton: NSButton?
    private var loadingIndicator: NSProgressIndicator?
    private var xAtok: String?
    private var hasBootstrapUser = false
    private var cookies: [HTTPCookie] = []
    private var pollTimer: Timer?
    private var isFinishing = false
    private var isCompletingSession = false
    private var userEmail: String?
    private var userDisplayName: String?
    private var userAvatarURL: String?

    func present(parentWindow: NSWindow? = nil, completion: @escaping (Result<DashboardSession, Error>) -> Void) {
        if let window {
            self.completion = completion
            if let parentWindow, window.sheetParent !== parentWindow {
                window.orderOut(nil)
                self.parentWindow = parentWindow
                parentWindow.beginSheet(window)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        self.completion = completion
        self.parentWindow = parentWindow
        showLoginWindow()
    }

    private func showLoginWindow() {
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
        container.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = makeToolbar()
        window.contentView = container
        container.addSubview(toolbar)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),

            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if let parentWindow {
            parentWindow.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
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

    private func makeToolbar() -> NSView {
        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")!, target: self, action: #selector(cancelLogin))
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        cancelButton = button

        let indicator = NSProgressIndicator(frame: .zero)
        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        container.addSubview(indicator)
        self.loadingIndicator = indicator

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),

            indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 20),
            indicator.heightAnchor.constraint(equalToConstant: 20),
        ])

        return container
    }

    private func setLoading(_ isLoading: Bool) {
        loadingIndicator?.isHidden = !isLoading
        cancelButton?.isEnabled = !isCompletingSession
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
              userID: typeof parsed?.data?.user?.id === "string" ? parsed.data.user.id : null,
              email: typeof parsed?.data?.user?.email === "string" ? parsed.data.user.email : null,
              username: typeof parsed?.data?.user?.username === "string" ? parsed.data.user.username : null,
              avatarURL:
                typeof parsed?.data?.user?.avatar_url === "string" ? parsed.data.user.avatar_url :
                typeof parsed?.data?.user?.profile_image_url === "string" ? parsed.data.user.profile_image_url :
                typeof parsed?.data?.user?.avatar === "string" ? parsed.data.user.avatar :
                typeof parsed?.data?.user?.image_url === "string" ? parsed.data.user.image_url :
                null,
              displayName:
                typeof parsed?.data?.user?.full_name === "string" ? parsed.data.user.full_name :
                typeof parsed?.data?.user?.display_name === "string" ? parsed.data.user.display_name :
                typeof parsed?.data?.user?.name === "string" ? parsed.data.user.name :
                typeof parsed?.data?.user?.username === "string" ? parsed.data.user.username :
                [parsed?.data?.user?.first_name, parsed?.data?.user?.last_name]
                  .filter(value => typeof value === "string" && value.trim().length > 0)
                  .join(" ") || null
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
                    self?.userEmail = payload["email"] as? String
                    self?.userDisplayName = payload["displayName"] as? String
                    self?.userAvatarURL = payload["avatarURL"] as? String
                    self?.hasBootstrapUser = !(userID?.isEmpty ?? true) && !(securityToken?.isEmpty ?? true)
                }
                self?.finishIfReady()
            }
        }
    }

    private func finishIfReady() {
        guard !isFinishing, !isCompletingSession else {
            return
        }
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
            cookies: cookies.map(DashboardCookie.init(cookie:)),
            accountID: nil,
            workerName: nil,
            userEmail: userEmail,
            userDisplayName: userDisplayName,
            userAvatarURL: userAvatarURL
        )

        isCompletingSession = true
        setLoading(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let client = DashboardAPIClient(session: session)
                let context = try await client.resolveSessionContext()
                let profile = try? await client.fetchCurrentUserProfile()
                let hydratedSession = DashboardSession(
                    capturedAt: session.capturedAt,
                    xAtok: session.xAtok,
                    cookies: session.cookies,
                    accountID: context.accountID,
                    workerName: context.workerName,
                    userEmail: profile?.email ?? session.userEmail,
                    userDisplayName: profile?.displayName ?? session.userDisplayName,
                    userAvatarURL: profile?.avatarURL ?? session.userAvatarURL
                )
                try DashboardSessionStore.save(hydratedSession)
                self.isCompletingSession = false
                finish(.success(hydratedSession))
            } catch {
                self.isCompletingSession = false
                finish(.failure(error))
            }
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
        let parentWindow = parentWindow

        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.contentView = NSView(frame: .zero)
        if let window, let parentWindow {
            parentWindow.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        self.window = nil
        self.parentWindow = nil
        self.webView = nil
        cancelButton = nil
        loadingIndicator = nil
        xAtok = nil
        hasBootstrapUser = false
        cookies = []
        userEmail = nil
        userDisplayName = nil
        userAvatarURL = nil
        isCompletingSession = false
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

    @objc
    private func cancelLogin() {
        finish(.failure(DashboardError.userCancelledLogin))
    }

    private static let acceptLanguage = "en-US,en;q=0.9"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
}

extension DashboardAuthenticator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if completion != nil {
            finish(.failure(DashboardError.userCancelledLogin))
            return false
        }
        return true
    }
}
