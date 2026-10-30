import SoleCloud
import AppKit
import WebKit
import SoleCore
import SoleLogic

@MainActor final class SonyWebsiteLogin: NSObject, SonyLoginPage, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SonyLogin, Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var completing = false
    private let spinner = NSProgressIndicator()
    private let address = NSTextField(labelWithString: "ca.account.sony.com")

    func signIn(url: URL, state: String) async throws -> SonyLogin {
        guard continuation == nil, url.scheme == "https", url.host == "ca.account.sony.com" else { throw PSNAuthorization.AuthError.unavailable }
        expectedState = state; completing = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self
        webView = web
        let header = NSView()
        address.font = .systemFont(ofSize: 12, weight: .medium)
        address.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        header.addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spinner.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14), spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        header.addSubview(address); address.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([address.centerXAnchor.constraint(equalTo: header.centerXAnchor), address.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        let stack = NSStackView(views: [header, web]); stack.orientation = .vertical
        stack.spacing = 0; stack.alignment = .width
        header.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = loc("PlayStation sign-in · Con"); panel.contentView = stack
        panel.minSize = NSSize(width: 480, height: 600)
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center()
        window = panel
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.finish(.failure(PSNAuthorization.AuthError.timedOut))
        }
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            web.load(URLRequest(url: url))
        }
    }
    func cancel() { finish(.failure(PSNAuthorization.AuthError.cancelled)) }
    func windowWillClose(_ notification: Notification) { cancel() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == PSNCallback.scheme {
            decisionHandler(.cancel)
            guard !completing, continuation != nil else { return }
            let code: String
            do { code = try PSNCallback.code(from: url, expectedState: expectedState) }
            catch let failure as PSNCallback.Failure { finish(.failure(PSNAuthorization.AuthError.callback(failure))); return }
            catch { finish(.failure(PSNAuthorization.AuthError.invalidCallback)); return }
            completing = true
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, self.continuation != nil else { return }
                self.finish(.success(SonyLogin(code: code, sso: SonySSO.credential(from: cookies))))
            }
            return
        }
        guard url.scheme == "https" || url.absoluteString == "about:blank" else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true, let host = url.host { address.stringValue = host }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { spinner.startAnimation(nil) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { spinner.stopAnimation(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled || completing { return }
        finish(.failure(PSNAuthorization.AuthError.unavailable))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(PSNAuthorization.AuthError.unavailable)) }
    private func finish(_ result: Result<SonyLogin, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; timeout?.cancel(); timeout = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        window?.delegate = nil; window?.close(); window = nil; webView = nil
        expectedState = ""; completing = false
        pending.resume(with: result)
    }
}
