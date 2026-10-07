import Foundation

/// Content is generated from Web/ by the build plugin and embedded in the executable.
enum WebAssets {
    struct Asset { let contentType: String; let body: Data }

    static func asset(path: String) -> Asset? {
        switch path {
        case "/": return Asset(contentType: "text/html; charset=utf-8", body: html)
        case "/app.js": return Asset(contentType: "text/javascript; charset=utf-8", body: script)
        case "/style.css": return Asset(contentType: "text/css; charset=utf-8", body: style)
        default: return nil
        }
    }
}
