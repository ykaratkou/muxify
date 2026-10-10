import AppKit
import WebKit
import XCTest

final class BrowserDeveloperToolsTests: XCTestCase {
    func testDeveloperExtrasSetterReceivesABoolean() {
        let preferences = Preferences()
        XCTAssertTrue(BrowserDeveloperTools.enable(in: preferences))
        XCTAssertTrue(preferences.enabled)
    }

    func testMissingDeveloperExtrasSetterIsSafe() {
        XCTAssertFalse(BrowserDeveloperTools.enable(in: NSObject()))
    }

    func testShowUsesThePagesInspectorAndRepeatedCallsFocusIt() {
        let inspector = Inspector()
        let webView = Page(inspector: inspector)
        XCTAssertTrue(BrowserDeveloperTools.show(for: webView))
        XCTAssertTrue(BrowserDeveloperTools.show(for: webView))
        XCTAssertEqual(inspector.showCalls, 2)
        XCTAssertEqual(inspector.closeCalls, 0)
    }

    func testCloseUsesTheSameInspector() {
        let first = Inspector()
        let second = Inspector()
        BrowserDeveloperTools.close(for: Page(inspector: first))
        XCTAssertEqual(first.closeCalls, 1)
        XCTAssertEqual(second.closeCalls, 0)
    }

    func testMissingInspectorOrActionsAreSafe() {
        for webView in [NSObject(), Page(inspector: nil), Page(inspector: NSObject())] {
            XCTAssertFalse(BrowserDeveloperTools.show(for: webView))
            BrowserDeveloperTools.close(for: webView)
        }
    }

    @MainActor func testTabsEnableInspectionAndPreserveTheirWebViewWhenSwitching() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["about:blank", "about:blank"], activeTab: 0, isOpen: true))
        defer { browser.tearDown() }
        let first = try XCTUnwrap(browser.activeTab)
        let webView = first.webView
        let pageView = first.pageView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.addSubview(pageView)
        // A docked inspector is another child of this same parent.
        let inspectorView = NSView()
        pageView.addSubview(inspectorView)
        XCTAssertTrue(webView.isInspectable)
        let preferences = webView.configuration.preferences
        let getter = NSSelectorFromString("_developerExtrasEnabled")
        XCTAssertTrue(preferences.responds(to: getter))
        if preferences.responds(to: getter) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let enabled = unsafeBitCast(preferences.method(for: getter), to: Getter.self)
            XCTAssertTrue(enabled(preferences, getter), "Inspect Element must be enabled before the page loads")
        }
        browser.selectTab(offset: 1)
        pageView.removeFromSuperview()
        XCTAssertFalse(browser.activeTab === first)
        browser.selectTab(offset: -1)
        host.addSubview(first.pageView)
        XCTAssertTrue(browser.activeTab === first)
        XCTAssertTrue(first.webView === webView)
        XCTAssertTrue(first.pageView === pageView)
        XCTAssertTrue(webView.superview === pageView)
        XCTAssertTrue(inspectorView.superview === pageView)
        browser.close(first)
        XCTAssertNil(webView.superview)
        XCTAssertNil(pageView.superview)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    /// Opt-in because opening the real inspector brings a disposable native
    /// window forward and requires a graphical macOS login.
    @MainActor func testNativeInspectorKeepsPageStateAndDockingAndClosesWithTab() async throws {
        guard ProcessInfo.processInfo.environment["MUXIFY_TEST_WEBKIT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MUXIFY_TEST_WEBKIT=1 to exercise the native inspector")
        }
        _ = NSApplication.shared
        let tab = BrowserTab(url: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.pageView
        defer {
            tab.close()
            window.contentView = nil
            window.close()
        }
        let webView = tab.webView
        let loaded = expectation(description: "test page loaded")
        let navigation = Navigation(onFinish: { loaded.fulfill() })
        webView.navigationDelegate = navigation
        let html = "<title>DevTools test</title><h1>Test page</h1><script>window.testValue = 42</script>"
        tab.load(try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())))
        await fulfillment(of: [loaded], timeout: 10)

        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        tab.showDeveloperTools()
        let getter = NSSelectorFromString("_inspector")
        let inspector = try XCTUnwrap(webView.perform(getter)?.takeUnretainedValue() as? NSObject)
        XCTAssertTrue(inspector.value(forKey: "webView") as? WKWebView === webView)
        // _WKInspector.webView is the inspected page, not the frontend. Find
        // the frontend among docked siblings or the newly opened native window.
        var frontend: WKWebView?
        var frontendReady = false
        var frontendLabels = ""
        for _ in 0..<100 {
            let roots = [tab.pageView] + NSApp.windows.filter { !existingWindows.contains(ObjectIdentifier($0)) }.compactMap(\.contentView)
            frontend = roots.compactMap { inspectorWebView(in: $0, excluding: webView) }.first
            let labels = try? await frontend?.evaluateJavaScript("document.body ? document.body.innerText + '\\n' + Array.from(document.querySelectorAll('[title], [aria-label]')).map(element => (element.title || '') + ' ' + (element.getAttribute('aria-label') || '')).join('\\n') : ''")
            frontendLabels = labels as? String ?? ""
            if ["Elements", "Network", "Console"].allSatisfy(frontendLabels.contains) {
                frontendReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(frontendReady, "The inspector must expose Elements, Network and Console: \(frontendLabels)")
        let inspectorView = try XCTUnwrap(frontend)
        XCTAssertEqual(inspector.value(forKey: "visible") as? Bool, true)
        let value = try await webView.evaluateJavaScript("window.testValue")
        XCTAssertEqual(value as? Int, 42, "Opening the inspector must not reload the page")

        tab.showDeveloperTools()
        XCTAssertTrue(inspectorView.window?.firstResponder === inspectorView)
        let attach = NSSelectorFromString("attach")
        XCTAssertTrue(inspector.responds(to: attach))
        if inspector.responds(to: attach) { inspector.perform(attach) }
        XCTAssertTrue(inspectorView.superview === tab.pageView)

        // Simulate SwiftUI destroying one Tab host and creating another.
        let pageView = tab.pageView
        window.contentView = NSView(frame: pageView.frame)
        XCTAssertNil(pageView.window)
        window.contentView = pageView
        XCTAssertTrue(inspectorView.superview === pageView)
        XCTAssertTrue(inspectorView.window === window)
        XCTAssertTrue(tab.webView === webView)
        tab.close()
        XCTAssertEqual(inspector.value(forKey: "visible") as? Bool, false)
        XCTAssertNil(inspectorView.superview)
    }

    @MainActor private func inspectorWebView(in view: NSView, excluding page: WKWebView) -> WKWebView? {
        if let webView = view as? WKWebView, webView !== page { return webView }
        return view.subviews.lazy.compactMap { self.inspectorWebView(in: $0, excluding: page) }.first
    }

    private final class Navigation: NSObject, WKNavigationDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    private final class Preferences: NSObject {
        var enabled = false
        @objc(_setDeveloperExtrasEnabled:) func setDeveloperExtrasEnabled(_ enabled: Bool) {
            self.enabled = enabled
        }
    }

    private final class Page: NSObject {
        let inspector: NSObject?
        init(inspector: NSObject?) { self.inspector = inspector }
        @objc func _inspector() -> NSObject? { inspector }
    }

    private final class Inspector: NSObject {
        var showCalls = 0
        var closeCalls = 0
        @objc func show() { showCalls += 1 }
        @objc func close() { closeCalls += 1 }
    }
}
