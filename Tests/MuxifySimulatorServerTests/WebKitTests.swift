import AppKit
import WebKit
import XCTest
@testable import MuxifySimulatorServer

// Optional check for the browser engine Muxify embeds. Uses a fake Device, not a live Simulator.
final class WebKitTests: XCTestCase {
    @MainActor
    func testEmbeddedBrowserLoadsAndControlsSimulatorPage() async throws {
        guard ProcessInfo.processInfo.environment["MUXIFY_TEST_WEBKIT"] == "1" else {
            throw XCTSkip("Opt in with MUXIFY_TEST_WEBKIT=1; requires a graphical macOS login.")
        }
        _ = NSApplication.shared
        var options = try ServerOptions(arguments: ["serve"]); options.port = 0
        let backend = MockBackend(), server = SimulatorServer(options: options, backend: backend)
        let port = try await server.start()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/#token=\(options.token)")!))
        do {
            try await wait(view, "document.getElementById('connection')?.textContent === 'Connected'")
            try await wait(view, "document.getElementById('devices')?.options.length === 3")
            _ = try await view.evaluateJavaScript("const menu=document.getElementById('devices'); menu.value='\(deviceA)'; menu.dispatchEvent(new Event('change'));")
            try await wait(view, "!document.getElementById('start').disabled")
            let boots = await backend.boots
            XCTAssertEqual(boots, 0)
            _ = try await view.evaluateJavaScript("document.getElementById('start').click()")
            try await wait(view, "document.getElementById('stop').disabled === false")
            backend.display.push()
            try await wait(view, "document.getElementById('screen').hidden === false")
            try await wait(view, "document.getElementById('device-frame').hidden === false")
            view.setFrameSize(NSSize(width: 320, height: 640))
            try await wait(view, "(() => { const r=document.getElementById('device-frame').getBoundingClientRect(); return r.width>0 && r.left>=0 && r.right<=innerWidth && r.bottom<=document.querySelector('footer').getBoundingClientRect().top && document.documentElement.scrollWidth<=innerWidth; })()")
            _ = try await view.evaluateJavaScript("document.getElementById('screen').dispatchEvent(new KeyboardEvent('keydown',{code:'KeyA',key:'a'}))")
            for _ in 0..<100 where backend.input.events.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(backend.input.events, ["key:down:4"])
            view.stopLoading()
            _ = try await view.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'))")
            await server.shutdown()
            XCTAssertEqual(backend.input.events, ["key:down:4", "key:up:4"])
        } catch {
            view.stopLoading()
            await server.shutdown()
            throw error
        }
    }

    @MainActor
    private func wait(_ view: WKWebView, _ expression: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let message = try? await view.evaluateJavaScript("document.getElementById('message')?.textContent")
        XCTFail("Timed out in WKWebView: \(expression); \(String(describing: message))")
        throw NSError(domain: "WebKitTests", code: 1)
    }
}
