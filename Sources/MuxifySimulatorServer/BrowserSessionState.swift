import Foundation

enum ServerMessage: Sendable { case text(Data), frame(Data) }

/// Per-browser selection, transport and frame acknowledgements. Device state is shared.
/// Only SimulatorSession's worker calls this actor, including teardown.
actor BrowserSessionState {
    private let id = UUID()
    private let backend: any SimulatorBackendProtocol
    private let sessions: DeviceSessions
    private let encoder: any FrameEncoding
    private let frameTimeout: TimeInterval
    private let send: @Sendable (ServerMessage) async throws -> Void
    private var devices: [DeviceInfo] = []
    private var selected: String?
    private var device: SharedDevice?
    private var snapshot: DeviceSnapshot?
    private var localStatus: SimulatorStatus = .choosing
    private var localMessage: String?
    private var status: SimulatorStatus { snapshot?.status ?? localStatus }
    private var orientation: DeviceOrientation { snapshot?.orientation ?? .portrait }
    private var lastRevision: UInt64?
    private var frameID: UInt32 = 0
    private var awaitingFrame: UInt32?
    private var frameSentAt = Date()
    private var closed = false

    init(backend: any SimulatorBackendProtocol, sessions: DeviceSessions,
         encoder: any FrameEncoding = JPEGFrameEncoder(),
         frameTimeout: TimeInterval = 15,
         send: @escaping @Sendable (ServerMessage) async throws -> Void) {
        self.backend = backend
        self.sessions = sessions
        self.encoder = encoder
        self.frameTimeout = frameTimeout
        self.send = send
    }

    func handle(_ command: ControlMessage) async {
        guard !closed else { return }
        do {
            localMessage = nil
            switch command {
            case .refresh: try await refresh()
            case .select(let selection):
                let next = selection?.uppercased()
                if selected != next {
                    await detach()
                    selected = next
                }
                try await refresh()
            case .start:
                guard let device else { return }
                try await publish(status: .connecting)
                try await device.attach(id, start: true)
                try await refresh()
            case .stop, .home, .rotate, .touch, .key, .release:
                try await device?.control(command, owner: id)
                switch command {
                case .stop: try await refresh()
                case .home, .rotate: try await synchronize()
                default: break
                }
            case .ack(let frame):
                if awaitingFrame == frame { awaitingFrame = nil }
            }
        } catch is CancellationError {
            // The worker will detach after cancellation; do not publish stale state.
            return
        } catch {
            localMessage = error.localizedDescription
            if let device {
                switch command {
                case .touch, .key:
                    do { try await device.control(.release, owner: id) }
                    catch { localMessage = "Could not release Device input: \(error.localizedDescription)" }
                default: break
                }
                snapshot = await device.snapshot()
            } else { localStatus = .unavailable }
            try? await publish()
        }
    }

    private func refresh() async throws {
        devices = try await backend.devices()
        if let selected {
            guard let info = devices.first(where: { $0.udid == selected }) else {
                await detach()
                throw SimulatorError.message("The selected Device is unavailable. Choose another Device.")
            }
            if device == nil { device = await sessions.device(selected) }
            guard let device else { return }
            if info.state == .shutdown || info.state == .shuttingDown {
                await device.stoppedExternally()
                // Register stopped selections too, so a peer's Start immediately reaches them.
                do { try await device.attach(id, start: false) }
                catch SimulatorError.stopped { }
            } else {
                try await device.attach(id, start: false)
            }
            snapshot = await device.snapshot()
        } else { localStatus = .choosing }
        try await publish()
    }

    private func synchronize() async throws {
        if let device { snapshot = await device.snapshot() }
        try await publish()
    }

    func streamFrame() async {
        guard !closed, let device else { return }
        let next = await device.snapshot()
        let changed = snapshot?.status != next.status || snapshot?.orientation != next.orientation
            || snapshot?.viewers != next.viewers || snapshot?.inputEpoch != next.inputEpoch || snapshot?.message != next.message
        snapshot = next
        do {
            if changed { try await publish() }
            guard status == .running else { return }
            if awaitingFrame != nil, Date().timeIntervalSince(frameSentAt) > frameTimeout {
                // A stalled browser must not tear down the display used by other browsers.
                await detach()
                localStatus = .unavailable
                localMessage = "Browser stopped acknowledging display frames. Choose Retry."
                try await publish()
                return
            }
            guard awaitingFrame == nil, next.revision != lastRevision, let frame = next.frame else { return }
            let jpeg = try encoder.encode(frame, orientation: orientation)
            frameID &+= 1
            var packet = Data()
            var number = frameID.bigEndian
            var rotation = UInt32(orientation.degrees).bigEndian
            withUnsafeBytes(of: &number) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: &rotation) { packet.append(contentsOf: $0) }
            packet.append(jpeg)
            awaitingFrame = frameID
            frameSentAt = Date()
            lastRevision = next.revision
            try await send(.frame(packet))
        } catch {
            await detach()
            localStatus = .unavailable
            localMessage = error.localizedDescription
            try? await publish()
        }
    }

    private func detach() async {
        await device?.detach(id)
        device = nil
        lastRevision = nil
        awaitingFrame = nil
        snapshot = nil
    }

    private func publish(status override: SimulatorStatus? = nil) async throws {
        struct State: Encodable {
            let type = "state"
            let devices: [DeviceInfo]
            let selected: String?
            let status: SimulatorStatus
            let rotation: Int
            let viewers: Int
            let inputEpoch: UInt64
            let message: String?
        }
        try await send(.text(JSONEncoder().encode(State(devices: devices, selected: selected,
            status: override ?? status, rotation: orientation.degrees, viewers: snapshot?.viewers ?? 0,
            inputEpoch: snapshot?.inputEpoch ?? 0, message: localMessage ?? snapshot?.message))))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await detach()
    }
}
