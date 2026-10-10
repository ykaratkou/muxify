import SwiftUI

/// Shared presentation for the Sidebar and Command Palette. Attention takes
/// priority over Unread; a working Agent never gets an Unread dot.
enum AgentStatusMarker: Equatable {
    case working, unread, attention

    init?(status: AgentStatus?, unread: Bool) {
        switch status {
        case .working: self = .working
        case .blocked, .failed: self = .attention
        case .done where unread: self = .unread
        case .done, nil: return nil
        }
    }

    var color: Color {
        switch self {
        case .working: .secondary
        case .unread: .blue
        case .attention: .orange
        }
    }
}

struct AgentStatusIndicator: View {
    let marker: AgentStatusMarker
    var dotSize: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch marker {
        case .working:
            TerminalActivityIndicator(reduceMotion: reduceMotion)
        case .unread, .attention:
            Circle().fill(marker.color).frame(width: dotSize, height: dotSize)
        }
    }
}

/// Square pixels light up one step at a time, like a terminal activity glyph.
/// Every visible indicator shares a clock; reduced motion has no animation timer.
struct TerminalActivityIndicator: View {
    let reduceMotion: Bool

    static let period: TimeInterval = 1.2

    static func phase(at date: Date) -> Double {
        let cycles = date.timeIntervalSinceReferenceDate / period
        return cycles - floor(cycles)
    }

    var body: some View {
        if reduceMotion {
            TerminalActivityGlyph(phase: 0)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0),
                                   by: Self.period / Double(TerminalActivityGlyph.cells.count))) { context in
                TerminalActivityGlyph(phase: Self.phase(at: context.date))
            }
        }
    }
}

/// Eight separate square pixels on a three-column, three-row perimeter. No outline
/// connects them: a bright head and two dimmer trailing pixels step clockwise.
struct TerminalActivityGlyph: View {
    let phase: Double

    @Environment(\.displayScale) private var displayScale

    static let blockSize: CGFloat = 3

    static let cells: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 1),
        CGPoint(x: 2, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 0, y: 2), CGPoint(x: 0, y: 1),
    ]

    static func head(at phase: Double) -> Int {
        // Wall-clock dates lose a little precision at exact tick boundaries.
        // This tolerance prevents a repeated pixel followed by a skipped one.
        let position = (phase - floor(phase)) * Double(cells.count)
        return Int(floor(position + 0.00001)) % cells.count
    }

    var body: some View {
        Canvas { context, size in
            let head = Self.head(at: phase)
            // Reserve a physical pixel for each gap. At 1×, use 2 pt blocks so
            // all eight stay separate within the same 10 pt footprint; at 2×,
            // retain the 3 pt blocks and half-point gaps.
            let gap = 1 / displayScale
            let availablePixels = min(size.width, size.height) * displayScale - 2
            let blockSize = min(Self.blockSize, floor(availablePixels / 3) / displayScale)
            let pitch = blockSize + gap
            let extent = 2 * pitch + blockSize
            // Align the entire grid to physical pixels to avoid antialiasing
            // that would blur adjacent blocks together.
            let origin = CGPoint(x: ((size.width - extent) / 2 * displayScale).rounded() / displayScale,
                                 y: ((size.height - extent) / 2 * displayScale).rounded() / displayScale)
            for (index, cell) in Self.cells.enumerated() {
                let behind = (head - index + Self.cells.count) % Self.cells.count
                let opacity: Double
                switch behind {
                case 0: opacity = 0.85
                case 1: opacity = 0.55
                case 2: opacity = 0.32
                default: opacity = 0.16
                }
                let block = CGRect(x: origin.x + cell.x * pitch, y: origin.y + cell.y * pitch,
                                   width: blockSize, height: blockSize)
                context.fill(Path(block), with: .color(.primary.opacity(opacity)))
            }
        }
        .frame(width: 10, height: 10)
    }
}
