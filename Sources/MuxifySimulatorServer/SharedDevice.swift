import Foundation

/// One backend connection per Device, irrespective of how many browser tabs select it.
actor DeviceSessions {
    private let backend: any SimulatorBackendProtocol
    private var devices: [String: SharedDevice] = [:]

    init(backend: any SimulatorBackendProtocol) { self.backend = backend }

    func device(_ udid: String) -> SharedDevice {
        if let device = devices[udid] { return device }
        let device = SharedDevice(udid: udid, backend: backend)
        devices[udid] = device
        return device
    }
}

struct DeviceSnapshot: Sendable {
    let orientation: DeviceOrientation
    let status: SimulatorStatus
    let message: String?
    let frame: DisplayFrame?
    let revision: UInt64
    let viewers: Int
    let inputEpoch: UInt64
}

actor SharedDevice {
    private let udid: String
    private let backend: any SimulatorBackendProtocol
    private var connection: SimulatorConnection?
    private var viewers = Set<UUID>()
    private var input: DeviceInput?
    private var orientation: DeviceOrientation = .portrait
    private var hasOrientation = false
    private var status: SimulatorStatus = .stopped
    private var message: String?
    private var frame: DisplayFrame?
    private var revision: UInt64 = 0
    private var inputEpoch: UInt64 = 0
    private var firstFrameAt = Date()
    private var displayTask: Task<Void, Never>?
    private var generation = UUID()
    private var tail: Task<Void, Never>?

    init(udid: String, backend: any SimulatorBackendProtocol) {
        self.udid = udid
        self.backend = backend
    }

    // Actor isolation alone is insufficient: awaiting the backend permits reentrancy.
    // Chain whole operations so input, rotation, boot and teardown remain FIFO across tabs.
    private func ordered<T: Sendable>(cancelWithCaller: Bool = true, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if cancelWithCaller { task.cancel() }
        }
    }

    func attach(_ owner: UUID, start: Bool) async throws {
        try await ordered { try await self.open(owner, start: start) }
    }

    private func open(_ owner: UUID, start: Bool) async throws {
        viewers.insert(owner)
        guard connection == nil else { return }
        status = .connecting
        message = nil
        do {
            let opened = try await backend.connect(udid: udid, startIfNeeded: start)
            connection = opened
            input = DeviceInput(opened.input)
            if !hasOrientation { orientation = opened.orientation; hasOrientation = true }
            firstFrameAt = Date()
            let token = generation
            displayTask = Task { [weak self] in
                for await frame in opened.display.frames {
                    guard !Task.isCancelled else { return }
                    await self?.received(frame, generation: token)
                }
                if !Task.isCancelled { await self?.displayEnded(generation: token) }
            }
        } catch {
            status = (error as? SimulatorError) == .stopped ? .stopped : .unavailable
            message = status == .stopped ? nil : error.localizedDescription
            throw error
        }
    }

    private func received(_ frame: DisplayFrame, generation token: UUID) {
        guard generation == token else { return }
        self.frame = frame
        revision &+= 1
        if status == .connecting { status = .running }
    }

    private func displayEnded(generation token: UUID) async {
        try? await ordered {
            guard await self.generation == token else { return }
            await self.failDisplay("Simulator display disconnected. Choose Retry.")
        }
    }

    private func failDisplay(_ error: String) async {
        await disconnect()
        status = .unavailable
        message = message.map { "\(error) \($0)" } ?? error
    }

    func snapshot() async -> DeviceSnapshot {
        if connection != nil, frame == nil, Date().timeIntervalSince(firstFrameAt) > 15, status != .rotating {
            try? await ordered { await self.checkDisplayTimeout() }
        }
        return DeviceSnapshot(orientation: orientation, status: status, message: message,
                              frame: frame, revision: revision, viewers: viewers.count, inputEpoch: inputEpoch)
    }

    private func checkDisplayTimeout() async {
        // Frames can arrive or another tab can retry while this check waits in the queue.
        guard connection != nil, frame == nil, Date().timeIntervalSince(firstFrameAt) > 15,
              status != .rotating else { return }
        await failDisplay("Simulator did not provide a display frame. Choose Retry.")
    }

    func control(_ command: ControlMessage, owner: UUID) async throws {
        try await ordered { try await self.apply(command, owner: owner) }
    }

    private func apply(_ command: ControlMessage, owner: UUID) async throws {
        guard viewers.contains(owner) else { return }
        switch command {
        case .stop:
            status = .stopping
            await disconnect()
            do { try await backend.stop(udid: udid); hasOrientation = false; status = .stopped; message = nil }
            catch { status = .unavailable; message = error.localizedDescription; throw error }
        case .rotate:
            guard connection != nil else { return }
            try await releaseAll()
            status = .rotating
            // Always rotate the physical frame, even when the guest app is portrait-only.
            do { orientation = try await backend.rotate(udid: udid, to: orientation.rotatedRight) }
            catch { status = frame == nil ? .connecting : .running; throw error }
            revision &+= 1
            status = frame == nil ? .connecting : .running
        case .home:
            try await releaseAll()
            try await input?.home()
        case .release: try await input?.release(owner)
        case .key(let event): try await input?.key(event, owner: owner)
        case .touch(let touch):
            guard status == .running, touch.orientation == orientation else { return }
            try await input?.touch(touch, owner: owner)
        default: break
        }
    }

    private func releaseAll() async throws {
        inputEpoch &+= 1
        try await input?.releaseAll()
    }

    private func disconnect() async {
        displayTask?.cancel(); displayTask = nil
        generation = UUID()
        message = nil
        do { try await releaseAll() }
        catch { message = "Could not release Device input: \(error.localizedDescription)" }
        if let connection {
            connection.input.close()
            connection.display.close()
            await backend.forget(udid: udid)
        }
        connection = nil
        input = nil
        frame = nil
        revision &+= 1
    }

    func stoppedExternally() async {
        try? await ordered { await self.markStopped() }
    }

    private func markStopped() async {
        // A peer may have completed Start since another browser polled the menu.
        if let info = try? await backend.devices().first(where: { $0.udid == udid }),
           info.state == .booted || info.state == .booting { return }
        await disconnect()
        hasOrientation = false
        status = message == nil ? .stopped : .unavailable
    }

    func detach(_ owner: UUID) async {
        // Teardown must run even when the browser's worker was cancelled.
        try? await ordered(cancelWithCaller: false) { await self.remove(owner) }
    }

    private func remove(_ owner: UUID) async {
        do { try await input?.release(owner) }
        catch { await failDisplay("Could not release Device input: \(error.localizedDescription)") }
        viewers.remove(owner)
        if viewers.isEmpty {
            await disconnect()
            status = message == nil ? .stopped : .unavailable
        }
    }
}
