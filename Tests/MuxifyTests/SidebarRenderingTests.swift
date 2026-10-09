import AppKit
import SwiftUI
import XCTest

final class SidebarRenderingTests: XCTestCase {
    /// Use real row presentation without starting Ghostty or a tmux connection.
    @MainActor func testNativeRowsGrowForLargerFontsAtNarrowWidth() throws {
        for scheme in [ColorScheme.light, .dark] {
            for family in ["system", try installedFamily()] {
                let small = try render(rows(), typography: SidebarTypography(fontFamily: family), scheme: scheme)
                let large = try render(rows(), typography: SidebarTypography(fontSize: 24, fontFamily: family), scheme: scheme)
                XCTAssertGreaterThan(large.height, small.height, "Rows must grow rather than vertically clip large text")
                XCTAssertGreaterThan(small.ink, 0)
                XCTAssertGreaterThan(large.ink, 0)
                XCTAssertEqual(small.width, 180)
                XCTAssertEqual(large.width, 180)
            }
        }
    }

    @MainActor func testSystemSessionHeaderKeepsItsDefaultHeightAndGrowsWhenNeeded() throws {
        let header = SessionHeader(session: SessionGroup(id: "$1", name: "AgM Session", windows: []),
                                   isExpanded: true, containsSelection: false, onToggle: {})
        let baseline = try render(header, typography: SidebarTypography(), scheme: .light)
        // 24-point header plus its existing one-point top padding.
        XCTAssertEqual(baseline.height, 25, accuracy: 0.5)
        let large = try render(header, typography: SidebarTypography(fontSize: 24), scheme: .light)
        XCTAssertGreaterThan(large.height, baseline.height)
    }

    @MainActor func testHostedProductionSidebarObservesConfigEditsAndRecovery() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-sidebar-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.yaml").path
        let defaults = UserDefaults.standard
        let keys = ["sidebarVisible", "sessionsVisible", "agentsVisible", "browserURLs", "browserVisible", "browserWidth"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let config = ConfigStore(path: path)
        let store = WorkspaceStore(configStore: config)
        store.sessionsVisible = true
        store.agentsVisible = false
        let host = NSHostingView(rootView: ConfiguredSidebar(store: store, config: config)
            .background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        let before = try snapshot(host).ink
        try "ui:\n  sidebar:\n    font_size: 24\n    font_family: system".write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        let larger = try snapshot(host).ink
        XCTAssertGreaterThan(larger, before)
        let family = try installedFamily()
        let quotedFamily = family.replacingOccurrences(of: "'", with: "''")
        try "ui:\n  sidebar:\n    font_size: 24\n    font_family: '\(quotedFamily)'"
            .write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        let custom = try snapshot(host).ink
        XCTAssertEqual(config.config.sidebarTypography.fontFamily, family)
        XCTAssertNotEqual(custom, larger, "A family-only edit must update the rendered text")
        try "ui: [".write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        XCTAssertEqual(try snapshot(host).ink, custom, "A syntax error must retain the rendered last-good font")
        try "ui:\n  sidebar:\n    font_size: 24\n    font_family: MuxifyMissingFont-\(UUID().uuidString)"
            .write(toFile: path, atomically: true, encoding: .utf8)
        config.reload()
        XCTAssertEqual(config.problems.count, 1)
        XCTAssertEqual(try snapshot(host).ink, larger, "An unavailable family falls back independently of size")
        try FileManager.default.removeItem(atPath: path)
        config.reload()
        XCTAssertEqual(try snapshot(host).ink, before)
        XCTAssertTrue(store.sessionsVisible)
        XCTAssertFalse(store.agentsVisible)
        withExtendedLifetime(window) {}
    }

    private struct ConfiguredSidebar: View {
        let store: WorkspaceStore
        let config: ConfigStore
        var body: some View { SidebarView(store: store, typography: config.config.sidebarTypography) }
    }

    @MainActor private func installedFamily() throws -> String {
        try XCTUnwrap(SidebarTypography.fontFamilies.first { family in
            SidebarTypography.lookup(family: family, weight: 5, size: 12) != nil
        })
    }

    @MainActor private func rows() -> some View {
        let window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "A very long Session name with AgM descenders",
                                index: 1, name: "shell", paneTitle: "A very long Window title with AgM descenders",
                                path: "/test", command: "fish", isActive: true, paneCount: 3, hasBell: true,
                                sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
        let agent = Agent(paneID: "%1", kind: .codex, status: .failed, unread: true, windowID: "@1", sessionID: "$1",
                          sessionName: window.sessionName, windowIndex: 1, windowTitle: window.displayTitle)
        return VStack(spacing: 0) {
            SessionHeader(session: SessionGroup(id: "$1", name: window.sessionName, windows: [window]),
                          isExpanded: false, containsSelection: true, onToggle: {})
            WindowRow(window: window, isSelected: false, tabCount: 12)
            WindowRow(window: window, isSelected: true, tabCount: 12)
            AgentRow(agent: agent)
        }
    }

    @MainActor private func render<V: View>(_ view: V, typography: SidebarTypography,
                                           scheme: ColorScheme) throws -> (width: CGFloat, height: CGFloat, ink: Int) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.sidebarTypography, typography)
            .frame(width: 180).background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        let image = try snapshot(host)
        withExtendedLifetime(window) {}
        return image
    }

    @MainActor private func snapshot<V: View>(_ host: NSHostingView<V>) throws -> (width: CGFloat, height: CGFloat, ink: Int) {
        host.window?.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        var ink = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9 { ink += 1 }
            }
        }
        return (host.bounds.width, host.bounds.height, ink)
    }
}
