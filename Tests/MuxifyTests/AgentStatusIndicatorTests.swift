import AppKit
import SwiftUI
import XCTest

final class AgentStatusIndicatorTests: XCTestCase {
    func testMarkerPriorityForEveryStatusAndUnreadFlag() {
        for unread in [false, true] {
            XCTAssertEqual(AgentStatusMarker(status: .working, unread: unread), .working)
            XCTAssertEqual(AgentStatusMarker(status: .blocked, unread: unread), .attention)
            XCTAssertEqual(AgentStatusMarker(status: .failed, unread: unread), .attention)
            XCTAssertEqual(AgentStatusMarker(status: .done, unread: unread), unread ? .unread : nil)
            XCTAssertNil(AgentStatusMarker(status: nil, unread: unread))
        }
    }

    func testPaletteStatusLabelsUseTheSameMonochromeBlueAndOrangeColors() {
        let theme = PaletteTheme(nil)
        for unread in [false, true] {
            XCTAssertEqual(theme.status(.working, unread: unread), .secondary)
            XCTAssertEqual(theme.status(.blocked, unread: unread), .orange)
            XCTAssertEqual(theme.status(.failed, unread: unread), .orange)
            XCTAssertEqual(theme.status(.done, unread: unread), unread ? .blue : nil)
            XCTAssertNil(theme.status(nil, unread: unread))
        }
    }

    func testWorkingPhaseAdvancesAndLoopsOnTheSharedClock() {
        let period = TerminalActivityIndicator.period
        for cycles in [0.0, 0.25, 0.92, 1.0, 1.25, 100.25, -0.75] {
            let phase = TerminalActivityIndicator.phase(at: Date(timeIntervalSinceReferenceDate: cycles * period))
            XCTAssertEqual(phase, cycles - floor(cycles), accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
        }
    }

    func testPixelCellsFormAThreeByThreeSquareInClockwiseOrder() {
        let cells = TerminalActivityGlyph.cells
        XCTAssertEqual(cells.count, 8)
        XCTAssertEqual(Set(cells.map(\.x)).count, 3)
        XCTAssertEqual(Set(cells.map(\.y)).count, 3)
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.x == 0 || cell.x == 2 || cell.y == 0 || cell.y == 2)
            XCTAssertEqual(cells.filter { $0 == cell }.count, 1)
            let next = cells[(index + 1) % cells.count]
            XCTAssertEqual(abs(next.x - cell.x) + abs(next.y - cell.y), 1)
        }
        XCTAssertEqual(cells[1], CGPoint(x: 1, y: 0))
        XCTAssertEqual(cells[2], CGPoint(x: 2, y: 0))
        XCTAssertEqual(cells[3], CGPoint(x: 2, y: 1))
    }

    func testSharedClockDoesNotRepeatOrSkipPixelsAtTickBoundaries() {
        let period = TerminalActivityIndicator.period
        let count = TerminalActivityGlyph.cells.count
        for cycle in [0.0, 10000.0, 700000000.0, -1.0] {
            for step in 0..<(count * 2) {
                let time = cycle * period + Double(step) * period / Double(count)
                let phase = TerminalActivityIndicator.phase(at: Date(timeIntervalSinceReferenceDate: time))
                XCTAssertEqual(TerminalActivityGlyph.head(at: phase), step % count)
            }
        }
    }

    @MainActor func testThreePointPixelsFitInATenPointIndicatorFootprint() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: TerminalActivityGlyph(phase: 0))
        XCTAssertEqual(host.fittingSize.width, 10)
        XCTAssertEqual(host.fittingSize.height, 10)
        XCTAssertEqual(TerminalActivityGlyph.blockSize, 3)
    }

    @MainActor func testWorkingGlyphIsAMonochromeSquareWithAnEmptyCenterInBothSchemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for phase in [0.0, 0.25, 0.92] {
                let image = try render(TerminalActivityGlyph(phase: phase), scheme: scheme)
                let background = try color(image, x: 0, y: 0)
                var xs: [Int] = []
                var ys: [Int] = []
                for y in 0..<image.pixelsHigh {
                    for x in 0..<image.pixelsWide {
                        let pixel = try color(image, x: x, y: y)
                        guard abs(pixel.redComponent - background.redComponent) > 0.04 else { continue }
                        XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.015)
                        XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.015)
                        xs.append(x)
                        ys.append(y)
                    }
                }
                let width = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min())
                let height = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min())
                XCTAssertEqual(width, height, "The pixel perimeter must be square")
                let center = try color(image, x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
                XCTAssertEqual(center.redComponent, background.redComponent, accuracy: 0.01)
            }
        }
    }

    @MainActor func testPixelsStepAlongThePerimeterRatherThanMovingContinuously() throws {
        let count = Double(TerminalActivityGlyph.cells.count)
        for scheme in [ColorScheme.light, .dark] {
            let first = try render(TerminalActivityGlyph(phase: 0.1 / count), scheme: scheme)
            let sameStep = try render(TerminalActivityGlyph(phase: 0.9 / count), scheme: scheme)
            let later = try render(TerminalActivityGlyph(phase: 1.1 / count), scheme: scheme)
            let looped = try render(TerminalActivityGlyph(phase: 1 + 0.1 / count), scheme: scheme)
            XCTAssertEqual(try pixels(first), try pixels(sameStep))
            XCTAssertNotEqual(try pixels(first), try pixels(later))
            XCTAssertEqual(try pixels(first), try pixels(looped))
        }
    }

    @MainActor func testWorkingGlyphDrawsEightSeparateSquareBlocksNotAnOutline() throws {
        for scheme in [ColorScheme.light, .dark] {
            let native = try render(TerminalActivityGlyph(phase: 0), scheme: scheme)
            let nativeScale = CGFloat(native.pixelsWide) / 32
            try assertSeparateBlocks(native, expectedSize: nativeScale == 1 ? 2 : 3)
            for scale in [CGFloat(1), 2] {
                for phase in [0.0, 0.25, 0.92] {
                    let image = try render(TerminalActivityGlyph(phase: phase), scheme: scheme, scale: scale)
                    XCTAssertEqual(image.pixelsWide, Int(32 * scale))
                    XCTAssertEqual(image.pixelsHigh, Int(24 * scale))
                    try assertSeparateBlocks(image, expectedSize: scale == 1 ? 2 : 3)
                }
            }
        }
    }

    private func assertSeparateBlocks(_ image: NSBitmapImageRep, expectedSize: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let background = try color(image, x: 0, y: 0).redComponent
        var remaining = Set(try pixels(image).enumerated().compactMap { index, red in
            abs(red - background) > 0.04 ? index : nil
        })
        var blocks = 0
        while let first = remaining.first {
            remaining.remove(first)
            var pending = [first]
            var xs: [Int] = []
            var ys: [Int] = []
            while let pixel = pending.popLast() {
                let x = pixel % image.pixelsWide
                let y = pixel / image.pixelsWide
                xs.append(x)
                ys.append(y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nextX = x + dx
                    let nextY = y + dy
                    guard (0..<image.pixelsWide).contains(nextX), (0..<image.pixelsHigh).contains(nextY) else { continue }
                    let next = nextY * image.pixelsWide + nextX
                    if remaining.remove(next) != nil { pending.append(next) }
                }
            }
            XCTAssertEqual(xs.max()! - xs.min()!, ys.max()! - ys.min()!, "Each disconnected block must be square",
                           file: file, line: line)
            let scale = CGFloat(image.pixelsWide) / 32
            XCTAssertEqual(CGFloat(xs.max()! - xs.min()! + 1) / scale, expectedSize,
                           "The rendered blocks must retain their gaps at each display scale",
                           file: file, line: line)
            blocks += 1
        }
        XCTAssertEqual(blocks, 8, "The pixels must have visible gaps, not form a continuous outline",
                       file: file, line: line)
    }

    @MainActor func testReduceMotionUsesTheStaticPixelGlyph() throws {
        for scheme in [ColorScheme.light, .dark] {
            let indicator = try render(TerminalActivityIndicator(reduceMotion: true), scheme: scheme)
            let staticGlyph = try render(TerminalActivityGlyph(phase: 0), scheme: scheme)
            XCTAssertEqual(try pixels(indicator), try pixels(staticGlyph))
        }
    }

    @MainActor func testUnreadAndAttentionDotsRenderBlueAndOrange() throws {
        for scheme in [ColorScheme.light, .dark] {
            let blue = try render(AgentStatusIndicator(marker: .unread), scheme: scheme)
            let orange = try render(AgentStatusIndicator(marker: .attention), scheme: scheme)
            let blueCenter = try color(blue, x: blue.pixelsWide / 2, y: blue.pixelsHigh / 2)
            let orangeCenter = try color(orange, x: orange.pixelsWide / 2, y: orange.pixelsHigh / 2)
            XCTAssertGreaterThan(blueCenter.blueComponent, blueCenter.redComponent + 0.3)
            XCTAssertGreaterThan(orangeCenter.redComponent, orangeCenter.blueComponent + 0.3)
            XCTAssertGreaterThan(orangeCenter.greenComponent, orangeCenter.blueComponent + 0.2)
        }
    }

    @MainActor func testSidebarAndPaletteRenderTheSameStatusHues() throws {
        let cases: [(AgentStatus?, Bool, Color?)] = [
            (.working, true, nil), (.done, true, .blue), (.done, false, nil),
            (.blocked, false, .orange), (.failed, true, .orange), (nil, false, nil),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (status, unread, expected) in cases {
                let agent = Agent(paneID: "%1", kind: .pi, status: status, unread: unread,
                                  windowID: "@1", sessionID: "$1", sessionName: "test", windowIndex: 1,
                                  windowTitle: "Agent")
                let item = PaletteItem(id: "agent:%1", kind: .agent, ref: .agent(agent), title: "Agent",
                                       subtitle: "Pi", path: "/test", target: "%1", logo: "pi",
                                       status: status, unread: unread)
                let row = try render(AgentRow(agent: agent), scheme: scheme, width: 180, height: 40)
                let icon = try render(PaletteIcon(source: .item(item), theme: PaletteTheme(nil)),
                                      scheme: scheme, width: 48, height: 48)
                for image in [row, icon] {
                    var colored = 0
                    for y in 0..<image.pixelsHigh {
                        for x in 0..<image.pixelsWide {
                            let pixel = try color(image, x: x, y: y)
                            let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                            guard components.max()! - components.min()! > 0.1 else { continue }
                            colored += 1
                            if expected == .blue {
                                XCTAssertGreaterThan(pixel.blueComponent, pixel.redComponent)
                            } else if expected == .orange {
                                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                                XCTAssertGreaterThan(pixel.greenComponent, pixel.blueComponent)
                            }
                        }
                    }
                    if expected == nil { XCTAssertEqual(colored, 0) }
                    else { XCTAssertGreaterThan(colored, 0) }
                }
            }
        }
    }

    /// Native production rendering without Ghostty, tmux or a visible window.
    /// An explicit scale renders independently of the machine's attached display.
    @MainActor private func render<V: View>(_ view: V, scheme: ColorScheme,
                                           width: CGFloat = 32, height: CGFloat = 24,
                                           scale: CGFloat? = nil) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let content = view.frame(width: width, height: height)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme)
        if let scale {
            let renderer = ImageRenderer(content: content.environment(\.displayScale, scale))
            renderer.scale = scale
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        withExtendedLifetime(window) {}
        return image
    }

    private func color(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func pixels(_ image: NSBitmapImageRep) throws -> [CGFloat] {
        try (0..<image.pixelsHigh).flatMap { y in
            try (0..<image.pixelsWide).map { x in try color(image, x: x, y: y).redComponent }
        }
    }
}
