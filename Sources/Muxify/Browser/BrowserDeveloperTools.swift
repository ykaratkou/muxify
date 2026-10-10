import Foundation

/// WebKit exposes remote inspection publicly, but its in-app inspector and
/// Inspect Element preference are private. Keep those calls here and check
/// each selector before using it, so an OS change cannot crash the Browser.
enum BrowserDeveloperTools {
    @discardableResult
    static func enable(in preferences: NSObject) -> Bool {
        let selector = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: selector) else { return false }
        // This setter takes a BOOL, not an object; NSObject.perform is not safe here.
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(preferences.method(for: selector), to: Setter.self)
        setter(preferences, selector, true)
        return true
    }

    static func show(for webView: NSObject) -> Bool {
        let selector = NSSelectorFromString("show")
        guard let inspector = inspector(for: webView), inspector.responds(to: selector) else { return false }
        inspector.perform(selector)
        return true
    }

    static func close(for webView: NSObject) {
        let selector = NSSelectorFromString("close")
        guard let inspector = inspector(for: webView), inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    private static func inspector(for webView: NSObject) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }
}
