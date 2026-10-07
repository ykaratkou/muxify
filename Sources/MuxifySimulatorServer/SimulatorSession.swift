import Foundation

/// Owns the per-browser FIFO, coalesced ticks and cancellation. Socket handlers only
/// submit commands and close; actor reentrancy cannot interleave browser operations.
final class SimulatorSession: @unchecked Sendable {
    private let mailbox = SessionMailbox()
    private let worker: Task<Void, Never>
    private let onOverflow: @Sendable () -> Void
    private let lock = NSLock()
    private var ticker: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(backend: any SimulatorBackendProtocol, sessions: DeviceSessions,
         encoder: any FrameEncoding = JPEGFrameEncoder(), frameTimeout: TimeInterval = 15,
         onOverflow: @escaping @Sendable () -> Void = {},
         send: @escaping @Sendable (ServerMessage) async throws -> Void) {
        self.onOverflow = onOverflow
        let state = BrowserSessionState(backend: backend, sessions: sessions, encoder: encoder,
                                       frameTimeout: frameTimeout, send: send)
        let mailbox = self.mailbox
        worker = Task {
            for await work in mailbox.stream {
                if Task.isCancelled { break }
                switch work.kind {
                case .command(let command): await state.handle(command)
                case .poll: await state.handle(.refresh)
                case .frame: await state.streamFrame()
                }
                mailbox.complete(work)
            }
            await state.close()
        }
    }

    /// Start periodic work for a live connection. Tests can drive commands/ticks directly.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started, !stopped else { return }
        started = true
        let mailbox = self.mailbox, onOverflow = self.onOverflow
        _ = mailbox.submit(.poll)
        ticker = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(67)) }
                catch { break }
                ticks += 1
                guard mailbox.submit(.frame), ticks % 30 != 0 || mailbox.submit(.poll) else {
                    self?.stop()
                    onOverflow()
                    break
                }
            }
        }
    }

    func enqueue(_ command: ControlMessage) {
        if !mailbox.submit(.command(command)) { stop(); onOverflow() }
    }

    func handle(_ command: ControlMessage) async {
        await submitAndWait(.command(command))
    }

    func streamFrame() async { await submitAndWait(.frame) }

    private func submitAndWait(_ kind: SessionMailbox.Kind) async {
        await withCheckedContinuation { completion in
            if !mailbox.submit(kind, completion: completion) { stop(); onOverflow() }
        }
    }

    /// Synchronous cancellation is safe in channelInactive and deinit.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        ticker?.cancel()
        mailbox.close()
        worker.cancel()
    }

    func close() async {
        stop()
        await worker.value
    }

    deinit { stop() }
}

private final class SessionMailbox: @unchecked Sendable {
    enum Kind: Sendable { case command(ControlMessage), poll, frame }
    struct Work: Sendable { let id = UUID(); let kind: Kind }
    let stream: AsyncStream<Work>
    private let continuation: AsyncStream<Work>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var pendingTicks = Set<Tick>()
    private var completions: [UUID: CheckedContinuation<Void, Never>] = [:]
    private enum Tick { case poll, frame }

    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(256)) }

    func submit(_ kind: Kind, completion: CheckedContinuation<Void, Never>? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { completion?.resume(); return false }
        // Awaited test ticks are real operations; only periodic fire-and-forget work coalesces.
        let tick = tick(kind)
        if completion == nil, let tick, pendingTicks.contains(tick) { return true }
        let work = Work(kind: kind)
        switch continuation.yield(work) {
        case .enqueued:
            if let tick { pendingTicks.insert(tick) }
            completions[work.id] = completion
            return true
        case .dropped, .terminated:
            completion?.resume()
            return false
        @unknown default:
            completion?.resume()
            return false
        }
    }

    func complete(_ work: Work) {
        lock.lock()
        if let tick = tick(work.kind) { pendingTicks.remove(tick) }
        let completion = completions.removeValue(forKey: work.id)
        lock.unlock()
        completion?.resume()
    }

    func close() {
        lock.lock()
        closed = true
        continuation.finish()
        let waiting = Array(completions.values)
        completions.removeAll()
        lock.unlock()
        for completion in waiting { completion.resume() }
    }

    private func tick(_ kind: Kind) -> Tick? {
        switch kind {
        case .poll: return .poll
        case .frame: return .frame
        case .command: return nil
        }
    }
}
