import CoreGraphics
import Foundation

/// The wire format stays small; invalid combinations cannot enter the session queue.
enum ControlMessage: Sendable {
    case refresh, select(String?), start, stop, home, rotate, release
    case touch(TouchCommand), key(KeyEvent), ack(UInt32)

    struct TouchCommand: Sendable {
        let phase: TouchEvent.Phase
        let point: CGPoint
        let orientation: DeviceOrientation
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw SimulatorError.message("Control message is too large.") }
        let wire = try JSONDecoder().decode(WireMessage.self, from: data)
        switch wire.type {
        case .refresh: return .refresh
        case .select:
            guard let device = wire.device else { return .select(nil) }
            guard let id = UUID(uuidString: device) else { throw SimulatorError.message("Invalid Device identifier.") }
            return .select(id.uuidString)
        case .start: return .start
        case .stop: return .stop
        case .home: return .home
        case .rotate: return .rotate
        case .release: return .release
        case .touch:
            let phases: [String: TouchEvent.Phase] = ["began": .began, "moved": .moved, "ended": .ended, "cancelled": .cancelled]
            guard let phase = wire.phase.flatMap({ phases[$0] }),
                  let x = wire.x, let y = wire.y, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y),
                  let rotation = wire.rotation, [0, 90, 180, 270].contains(rotation) else {
                throw SimulatorError.message("Invalid touch event.")
            }
            return .touch(TouchCommand(phase: phase, point: CGPoint(x: x, y: y), orientation: .fromDegrees(rotation)))
        case .key:
            guard let phase = wire.phase, ["down", "up"].contains(phase), let usage = wire.usage,
                  (4...0x73).contains(usage) || (0xe0...0xe7).contains(usage) else {
                throw SimulatorError.message("Invalid keyboard event.")
            }
            return .key(KeyEvent(phase: phase == "down" ? .down : .up, usage: usage))
        case .ack:
            guard let frame = wire.frame else { throw SimulatorError.message("Missing frame acknowledgement.") }
            return .ack(frame)
        }
    }

    /// Optional fields exist only while decoding untrusted JSON.
    private struct WireMessage: Decodable {
        enum Kind: String, Decodable { case refresh, select, start, stop, home, rotate, touch, key, release, ack }
        let type: Kind
        let device: String?
        let phase: String?
        let x: Double?
        let y: Double?
        let usage: UInt32?
        let rotation: Int?
        let frame: UInt32?
    }
}

enum SimulatorStatus: String, Encodable, Sendable {
    case choosing, stopped, connecting, running, stopping, rotating, unavailable
}
