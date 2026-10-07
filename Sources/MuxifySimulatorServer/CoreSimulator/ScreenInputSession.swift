import Foundation
import XPC

/// All input uses the screen-addressed digitizer. The guest drops legacy HID once
/// this feature is activated, including when another viewer activated it first.
final class ScreenInputSession: InputSession, @unchecked Sendable {
    static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"
    private static let activationAttempts = 5
    private let connection: xpc_connection_t
    private let target: UInt64
    private let queue = DispatchQueue(label: "dev.muxify.simulator.input", qos: .userInteractive)
    private let lock = NSLock()
    private var isActivated = false
    private var isClosed = false

    init(port: mach_port_t, screenID: Int) throws {
        connection = try SimulatorXPC.connect(port: port, queue: queue)
        target = UInt64(screenID)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    deinit { close() }

    func touch(_ event: TouchEvent) async throws {
        try await activate()
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", event.point.x)
        xpc_dictionary_set_double(point, "y", event.point.y)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "pointOne", point)
        let phase: UInt64
        switch event.phase {
        case .began: phase = 0
        case .moved: phase = 1
        case .ended, .cancelled: phase = 2
        }
        let edge: UInt64
        switch event.edge {
        case .none: edge = 0
        case .top: edge = 1
        case .left: edge = 2
        case .bottom: edge = 3
        case .right: edge = 4
        }
        xpc_dictionary_set_uint64(payload, "eventType", phase)
        xpc_dictionary_set_uint64(payload, "edge", edge)
        xpc_dictionary_set_uint64(payload, "target", target)
        send("IndigoDigitizerEvent", payload: payload)
    }

    func key(_ event: KeyEvent) async throws {
        try await activate()
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(event.usage))
        xpc_dictionary_set_uint64(payload, "state", event.phase == .down ? 1 : 2)
        send("IndigoKeyboardButtonEvent", payload: payload)
    }

    func home(phase: KeyEvent.Phase) async throws {
        try await activate()
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", 0x0c)
        xpc_dictionary_set_uint64(payload, "usageCode", 0x40)
        xpc_dictionary_set_uint64(payload, "state", phase == .down ? 1 : 2)
        send("IndigoButtonEvent", payload: payload)
    }

    private func message(_ type: String, payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    private func send(_ type: String, payload: xpc_object_t) {
        xpc_connection_send_message(connection, message(type, payload: payload))
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        xpc_connection_cancel(connection)
    }

    private func activationState() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { throw CoreSimulatorError.inputSessionClosed }
        return isActivated
    }

    private func markActivated() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { throw CoreSimulatorError.inputSessionClosed }
        isActivated = true
    }

    // Input is ordered by SharedDevice. Only close and XPC callbacks can run
    // concurrently. A barrier reply confirms activation; silence is not success.
    private func activate() async throws {
        try Task.checkCancellation()
        guard try !activationState() else { return }
        for attempt in 1...Self.activationAttempts {
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "usageCode", 0)
            xpc_dictionary_set_uint64(payload, "state", 2)
            let request = message("IndigoKeyboardButtonEvent", payload: payload, barrier: true)
            do {
                _ = try await SimulatorXPC.request(connection, message: request, queue: queue, timeout: 4)
                // The guest needs a moment before it starts acting on input reports.
                try await Task.sleep(for: .milliseconds(150))
                try markActivated()
                return
            } catch {
                try Task.checkCancellation()
                guard attempt < Self.activationAttempts else { throw error }
                try await Task.sleep(for: .seconds(4))
            }
        }
    }
}
