import CoreGraphics
import Foundation
import IOSurface

enum DeviceState: String, Sendable, Encodable {
    case shutdown, booting, booted, shuttingDown, unknown

    static func from(state: UInt, stateString: String) -> DeviceState {
        switch state {
        case 1: .shutdown
        case 2: .booting
        case 3: .booted
        case 4: .shuttingDown
        default:
            switch stateString.lowercased().filter({ !$0.isWhitespace }) {
            case "shutdown": .shutdown
            case "booting": .booting
            case "booted": .booted
            case "shuttingdown": .shuttingDown
            default: .unknown
            }
        }
    }
}

struct DeviceInfo: Sendable, Encodable {
    let udid: String
    let name: String
    let deviceTypeIdentifier: String
    let runtimeName: String
    let state: DeviceState
    let isAvailable: Bool
}

struct DisplayFrame: @unchecked Sendable {
    let surface: IOSurfaceRef
}

struct TouchEvent: Sendable {
    enum Phase: Sendable { case began, moved, ended, cancelled }
    // The guest uses the starting edge to recognize system gestures.
    enum Edge: Sendable { case none, top, left, bottom, right }
    let phase: Phase
    /// Normalized 0...1 in portrait-native coordinates, with a top-left origin.
    let point: CGPoint
    let edge: Edge
}

struct KeyEvent: Sendable, Equatable {
    enum Phase: Sendable { case down, up }
    let phase: Phase
    /// HID keyboard-page usage, not a macOS virtual keycode.
    let usage: UInt32
}

protocol DisplaySession: AnyObject, Sendable {
    var frames: AsyncStream<DisplayFrame> { get }
    func close()
}

protocol InputSession: AnyObject, Sendable {
    func touch(_ event: TouchEvent) async throws
    func key(_ event: KeyEvent) async throws
    func home(phase: KeyEvent.Phase) async throws
    func close()
}
