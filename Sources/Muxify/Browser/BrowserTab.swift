import AppKit
import Observation
import WebKit

/// One Tab in a Window's Browser: a page with its own history. The
/// WKWebView is created the first time the Tab is shown, so Tabs restored
/// from tmux cost nothing until you look at them.
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()

    private(set) var urlString: String
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0

    /// Whether the Tab shows (or will show, once loaded) a page.
    var hasPage: Bool { !urlString.isEmpty }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = URL(string: urlString)?.host { return host }
        return urlString.isEmpty ? "New Tab" : urlString
    }

    /// target=_blank links and window.open ask for a new Tab.
    @ObservationIgnored var onOpenInNewTab: ((URL) -> Void)?
    /// The Tab's URL changed (for persisting the Browser).
    @ObservationIgnored var onURLChange: (() -> Void)?
    /// The current URL was copied, for the App Window's confirmation pill.
    @ObservationIgnored var onCopyURL: ((String) -> Void)?

    @ObservationIgnored private var loadedWebView: WKWebView?
    @ObservationIgnored private var loadedPageView: NSView?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        // One persistent profile shared by every Tab, like a normal browser.
        config.websiteDataStore = .default()
        // Without a Safari token some sites serve degraded "unsupported browser" pages.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        BrowserDeveloperTools.enable(in: config.preferences)
        return config
    }()

    init(url: URL?) {
        pendingURL = url
        urlString = url?.absoluteString ?? ""
        super.init()
    }

    var webView: WKWebView {
        if let loadedWebView { return loadedWebView }
        let webView = WKWebView(frame: .zero, configuration: Self.configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        loadedWebView = webView
        observe(webView)
        if let pendingURL {
            self.pendingURL = nil
            load(pendingURL)
        }
        return webView
    }

    /// WebKit docks its inspector as a sibling of the page. Keep their parent
    /// alive with the Tab, so switching Tabs or Windows moves both together.
    var pageView: NSView {
        if let loadedPageView { return loadedPageView }
        let container = NSView()
        let webView = webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        loadedPageView = container
        return container
    }

    /// Stops the page and releases its web content.
    func close() {
        if let loadedWebView { BrowserDeveloperTools.close(for: loadedWebView) }
        loadedWebView?.stopLoading()
        loadedWebView?.removeFromSuperview()
        loadedPageView?.removeFromSuperview()
        loadedPageView = nil
        loadedWebView = nil
        observations = []
    }

    /// Key for "is this URL already open": ignores the fragment, a trailing
    /// slash, and the case of the scheme and host.
    static func matchKey(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return string }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var key = components.string ?? string
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                self?.update { tab in
                    guard let url = webView.url?.absoluteString, url != tab.urlString else { return }
                    tab.urlString = url
                    tab.onURLChange?()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                self?.update { $0.title = webView.title ?? "" }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                self?.update { $0.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                self?.update { $0.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                self?.update { $0.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                self?.update { $0.progress = webView.estimatedProgress }
            },
        ]
    }

    private func update(_ change: @escaping (BrowserTab) -> Void) {
        if Thread.isMainThread {
            change(self)
        } else {
            DispatchQueue.main.async { [weak self] in self.map(change) }
        }
    }

    // MARK: - Navigation

    /// Loads whatever the user typed: a URL, a bare host, or a search query.
    func open(_ input: String) {
        guard let url = Omnibox.url(for: input) else { return }
        load(url)
    }

    func load(_ url: URL) {
        let changed = url.absoluteString != urlString
        urlString = url.absoluteString
        if let loadedWebView {
            if url.isFileURL {
                loadedWebView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                loadedWebView.load(URLRequest(url: url))
            }
        } else {
            pendingURL = url
        }
        if changed { onURLChange?() }
    }

    func goBack() { loadedWebView?.goBack() }
    func goForward() { loadedWebView?.goForward() }

    func reloadOrStop() {
        guard let loadedWebView else { return }
        if loadedWebView.isLoading { loadedWebView.stopLoading() } else { loadedWebView.reload() }
    }

    func openInDefaultBrowser() {
        guard let url = URL(string: urlString), hasPage else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens (or focuses) this Tab's inspector without loading a second page.
    func showDeveloperTools() {
        guard hasPage else { return }
        let webView = webView
        guard BrowserDeveloperTools.enable(in: webView.configuration.preferences),
              BrowserDeveloperTools.show(for: webView) else {
            let alert = NSAlert()
            alert.messageText = "Developer Tools Unavailable"
            alert.informativeText = "This version of WebKit does not support opening Developer Tools in Muxify. You can inspect this Tab from Safari’s Develop menu instead."
            alert.alertStyle = .warning
            if let window = webView.window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
            return
        }
    }

    func copyURL() {
        copyURL(to: .general)
    }

    func copyURL(to pasteboard: NSPasteboard) {
        guard hasPage else { return }
        pasteboard.clearContents()
        if pasteboard.setString(urlString, forType: .string) { onCopyURL?(urlString) }
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    /// target=_blank links and window.open become a new Tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            onOpenInNewTab?(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("muxify: browser failed \(webView.url?.absoluteString ?? "-"): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("muxify: browser failed to start \(webView.url?.absoluteString ?? "-"): \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // Hand mailto:, zoommtg:, etc. to the system.
        if !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

enum Omnibox {
    static func url(for rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            return URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }
        if looksLikeHost(input) {
            let local = isLocal(input)
            return URL(string: (local ? "http://" : "https://") + input)
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        if isLocal(input) { return true }
        let host = input.split(whereSeparator: { "/:?#".contains($0) }).first.map(String.init) ?? input
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    private static func isLocal(_ input: String) -> Bool {
        let host = input.split(whereSeparator: { "/:?#".contains($0) }).first.map { $0.lowercased() } ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "[::1]"
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test")
            || (input.first?.isNumber == true && input.contains(":"))
    }
}
