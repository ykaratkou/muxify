import Foundation
import XCTest
@testable import MuxifySimulatorServer

final class SessionLifecycleTests: XCTestCase {
    func testSessionSerializesCommandsWithoutSocketWorker() async throws {
        let backend = MockBackend(state: .booted)
        await backend.delayRotations()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend)) { _ in }
        await session.handle(.select(deviceA))
        session.enqueue(.rotate)
        session.enqueue(.rotate)
        await session.handle(.refresh) // FIFO barrier, including backend suspension.
        let orientation = await backend.rotation
        XCTAssertEqual(orientation, .portraitUpsideDown)
        await session.close()
    }

    func testCloseCancelsBootWaitDiscardsQueuedStopAndPreservesPeer() async throws {
        let backend = SuspendedBootBackend(), sessions = DeviceSessions(backend: backend)
        let a = SimulatorSession(backend: backend, sessions: sessions) { _ in }
        let b = SimulatorSession(backend: backend, sessions: sessions) { _ in }
        await a.handle(.select(deviceA))
        a.enqueue(.start)
        await backend.waitUntilBootWaitStarted()
        a.enqueue(.stop) // Closing must not drain destructive commands from this browser.
        let peer = Task { await b.handle(.select(deviceA)) }
        let start = Date()
        await a.close()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await peer.value
        let cancellations = await backend.cancellations
        let state = await backend.base.state, stops = await backend.base.stops
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(state, .booted)
        XCTAssertEqual(stops, 0)
        await b.handle(.key(KeyEvent(phase: .down, usage: 4)))
        XCTAssertEqual(backend.base.input.events.last, "key:down:4")
        XCTAssertFalse(backend.base.input.closed)
        await b.close()
        XCTAssertEqual(backend.base.input.events.last, "key:up:4")
    }

    func testServerShutdownCancelsSuspendedBootWait() async throws {
        var options = try ServerOptions(arguments: ["serve"]); options.port = 0
        let backend = SuspendedBootBackend(), server = SimulatorServer(options: options, backend: backend)
        let port = try await server.start()
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws?token=\(options.token)")!)
        socket.resume()
        _ = try await socket.receive()
        try await socket.send(.string("{\"type\":\"select\",\"device\":\"\(deviceA)\"}"))
        _ = try await socket.receive()
        try await socket.send(.string(#"{"type":"start"}"#))
        await backend.waitUntilBootWaitStarted()
        let start = Date()
        await server.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let cancelled = await backend.cancellations, stops = await backend.base.stops
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(stops, 0)
        socket.cancel(with: .normalClosure, reason: nil)
    }

    func testQueueOverflowClosesSessionAndCancelsInFlightWork() async throws {
        let backend = SuspendedBootBackend()
        let overflow = expectation(description: "overflow closes transport")
        overflow.assertForOverFulfill = false
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend),
                                       onOverflow: { overflow.fulfill() }) { _ in }
        await session.handle(.select(deviceA))
        session.enqueue(.start)
        await backend.waitUntilBootWaitStarted()
        for _ in 0..<257 { session.enqueue(.rotate) }
        await fulfillment(of: [overflow], timeout: 1)
        await session.close()
        let cancelled = await backend.cancellations
        XCTAssertEqual(cancelled, 1)
    }

    func testReconnectGetsFreshDisplayAndStillStreams() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let a = SimulatorSession(backend: backend, sessions: sessions) { _ in }
        await a.handle(.select(deviceA))
        let oldInput = backend.input, oldDisplay = backend.display
        await a.close()
        let frame = expectation(description: "reconnected browser receives new display")
        let b = SimulatorSession(backend: backend, sessions: sessions) { message in
            if case .frame = message { frame.fulfill() }
        }
        await b.handle(.select(deviceA))
        XCTAssertFalse(oldInput === backend.input)
        XCTAssertFalse(oldDisplay === backend.display)
        XCTAssertTrue(oldInput.closed)
        b.start()
        backend.display.push()
        await fulfillment(of: [frame], timeout: 2)
        await b.close()
    }
}

private actor SuspendedBootBackend: SimulatorBackendProtocol {
    nonisolated let base = MockBackend()
    private var waiting = false
    private var observer: CheckedContinuation<Void, Never>?
    var cancellations = 0
    func devices() async -> [DeviceInfo] { await base.devices() }
    func connect(udid: String, startIfNeeded: Bool) async throws -> SimulatorConnection {
        if startIfNeeded, !waiting {
            await base.setState(.booted) // The Device is booting independently of our wait.
            waiting = true
            observer?.resume(); observer = nil
            do { try await Task.sleep(for: .seconds(3)) }
            catch { cancellations += 1; throw error }
        }
        return try await base.connect(udid: udid, startIfNeeded: startIfNeeded)
    }
    func waitUntilBootWaitStarted() async {
        if waiting { return }
        await withCheckedContinuation { observer = $0 }
    }
    func rotate(udid: String, to orientation: DeviceOrientation) async throws -> DeviceOrientation {
        try await base.rotate(udid: udid, to: orientation)
    }
    func stop(udid: String) async { await base.stop(udid: udid) }
    func forget(udid: String) async { await base.forget(udid: udid) }
}
