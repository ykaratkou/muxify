import Foundation
import XCTest
@testable import MuxifySimulatorServer

final class InputOwnershipTests: XCTestCase {
    func testFailedKeyUpIsRetriedBySessionErrorCleanup() async throws {
        let backend = InputBackend()
        await backend.input.failKeyUps(1)
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend)) { _ in }
        await session.handle(.select(deviceA))
        await session.handle(.key(KeyEvent(phase: .down, usage: 4)))
        await session.handle(.key(KeyEvent(phase: .up, usage: 4)))
        let held = await backend.input.keys
        let attempts = await backend.input.keyUpAttempts
        XCTAssertTrue(held.isEmpty)
        XCTAssertEqual(attempts, 2)
        await session.close()
    }

    func testReleaseCancelsTheHeldContact() async throws {
        let backend = InputBackend()
        let shared = SharedDevice(udid: deviceA, backend: backend)
        let owner = UUID()
        try await shared.attach(owner, start: false)
        backend.display.push()
        for _ in 0..<100 {
            if await shared.snapshot().status == .running { break }
            await Task.yield()
        }
        try await shared.control(.touch(.init(phase: .began, point: CGPoint(x: 0.5, y: 0.5), orientation: .portrait)), owner: owner)
        try await shared.control(.release, owner: owner)
        let phases = await backend.input.touchPhases
        XCTAssertEqual(phases, [.began, .cancelled])
        let held = await backend.input.contactHeld
        XCTAssertFalse(held)
        await shared.detach(owner)
    }

    func testFailedContactReleaseIsRetried() async throws {
        let input = FaultInput()
        let ownership = DeviceInput(input), owner = UUID()
        try await ownership.touch(.init(phase: .began, point: CGPoint(x: 0.2, y: 0.3), orientation: .portrait), owner: owner)
        await input.failTouchReleases(1)
        try await ownership.release(owner)
        let held = await input.contactHeld, attempts = await input.touchReleaseAttempts
        XCTAssertFalse(held)
        XCTAssertEqual(attempts, 2)
    }

    func testPermanentFailureIsReportedAndOwnershipSurvivesForLaterRetry() async throws {
        let input = FaultInput()
        let ownership = DeviceInput(input), owner = UUID()
        try await ownership.key(KeyEvent(phase: .down, usage: 4), owner: owner)
        try await ownership.key(KeyEvent(phase: .down, usage: 5), owner: owner)
        await input.failKeyUps(2)
        do {
            try await ownership.release(owner)
            XCTFail("Expected the exhausted release attempts to be reported")
        } catch { }
        let held = await input.keys
        XCTAssertEqual(held, [4], "Other keys should still be released when one fails")
        try await ownership.releaseAll()
        let remaining = await input.keys
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFailedReleaseDoesNotLiftAnotherViewersSharedKey() async throws {
        let input = FaultInput()
        let ownership = DeviceInput(input), a = UUID(), b = UUID()
        try await ownership.key(KeyEvent(phase: .down, usage: 225), owner: a)
        try await ownership.key(KeyEvent(phase: .down, usage: 225), owner: b)
        try await ownership.release(a)
        let held = await input.keys, attempts = await input.keyUpAttempts
        XCTAssertEqual(held, [225]); XCTAssertEqual(attempts, 0)
        await input.failKeyUps(1)
        try await ownership.release(b)
        let remaining = await input.keys
        XCTAssertTrue(remaining.isEmpty)
    }
}

private actor InputBackend: SimulatorBackendProtocol {
    nonisolated let input = FaultInput()
    nonisolated let display = MockDisplay()
    func devices() -> [DeviceInfo] {
        [DeviceInfo(udid: deviceA, name: "Test", deviceTypeIdentifier: "iPhone",
                    runtimeName: "iOS", state: .booted, isAvailable: true)]
    }
    func connect(udid: String, startIfNeeded: Bool) -> SimulatorConnection {
        SimulatorConnection(udid: udid, display: display, input: input, orientation: .portrait)
    }
    func rotate(udid: String, to orientation: DeviceOrientation) -> DeviceOrientation { orientation }
    func stop(udid: String) {}
    func forget(udid: String) {}
}

private actor FaultInput: InputSession {
    var keys = Set<UInt32>()
    var contactHeld = false
    var touchPhases: [TouchEvent.Phase] = []
    var keyUpAttempts = 0, touchReleaseAttempts = 0
    private var keyFailures = 0, touchFailures = 0
    func failKeyUps(_ count: Int) { keyFailures = count }
    func failTouchReleases(_ count: Int) { touchFailures = count }
    func key(_ event: KeyEvent) throws {
        if event.phase == .up {
            keyUpAttempts += 1
            if keyFailures > 0 { keyFailures -= 1; throw SimulatorError.message("Key-up failed") }
            keys.remove(event.usage)
        } else { keys.insert(event.usage) }
    }
    func touch(_ event: TouchEvent) throws {
        if event.phase == .ended || event.phase == .cancelled {
            touchReleaseAttempts += 1
            if touchFailures > 0 { touchFailures -= 1; throw SimulatorError.message("Touch release failed") }
            contactHeld = false
        } else { contactHeld = true }
        touchPhases.append(event.phase)
    }
    func home(phase: KeyEvent.Phase) {}
    nonisolated func close() {}
}
