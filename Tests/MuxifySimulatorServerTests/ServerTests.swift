import XCTest
import Foundation
import IOSurface
import ImageIO
import NIOHTTP1
@testable import MuxifySimulatorServer

let deviceA = "11111111-1111-1111-1111-111111111111"
let deviceB = "22222222-2222-2222-2222-222222222222"

final class ServerTests: XCTestCase {
    func testOptionsAreLoopbackOnlyAndValidateArguments() throws {
        let options = try ServerOptions(arguments: ["serve", "--port", "9000", "--origin", "https://mac.example/"])
        XCTAssertEqual(options.port, 9000)
        XCTAssertEqual(options.origins, ["https://mac.example"])
        XCTAssertEqual(options.token.count, 64)
        for args in [["serve", "--host", "0.0.0.0"], ["serve", "--port", "0"], ["serve", "--port", "70000"],
                     ["serve", "--origin", "https://mac.example/path"], ["serve", "--origin", "https://u:p@mac.example"]] {
            XCTAssertThrowsError(try ServerOptions(arguments: args))
        }
        XCTAssertThrowsError(try ServerOptions(arguments: ["serve"], environment: ["MUXIFY_SIMULATOR_TOKEN":"short"]))
        XCTAssertTrue(try ServerOptions(arguments: ["--help"]).help)
    }

    func testAuthenticationChecksTokenPathMethodAndOrigin() throws {
        let options = try ServerOptions(arguments: ["serve", "--origin", "https://remote.example"])
        func request(token: String, origin: String? = nil, path: String = "/ws", method: HTTPMethod = .GET) -> HTTPRequestHead {
            var headers = HTTPHeaders([("Host", "127.0.0.1:8787")])
            if let origin { headers.add(name: "Origin", value: origin) }
            return HTTPRequestHead(version: .http1_1, method: method, uri: "\(path)?token=\(token)", headers: headers)
        }
        XCTAssertTrue(RequestPolicy.authorizes(request(token: options.token), options: options))
        XCTAssertTrue(RequestPolicy.authorizes(request(token: options.token, origin: "http://127.0.0.1:8787"), options: options))
        XCTAssertTrue(RequestPolicy.authorizes(request(token: options.token, origin: "https://remote.example"), options: options))
        XCTAssertFalse(RequestPolicy.authorizes(request(token: options.token, origin: "https://evil.example"), options: options))
        XCTAssertFalse(RequestPolicy.authorizes(request(token: "bad"), options: options))
        XCTAssertFalse(RequestPolicy.authorizes(request(token: options.token, path: "/"), options: options))
        XCTAssertFalse(RequestPolicy.authorizes(request(token: options.token, method: .POST), options: options))
    }

    func testMalformedControlsAreRejected() {
        for text in [#"{"type":"shell"}"#, #"{"type":"select","device":"--all"}"#,
                     #"{"type":"touch","phase":"began","x":2,"y":0,"rotation":0}"#,
                     #"{"type":"key","phase":"down","usage":999}"#, #"{"type":"ack"}"#] {
            XCTAssertThrowsError(try ControlMessage.decode(Data(text.utf8)))
        }
        XCTAssertThrowsError(try ControlMessage.decode(Data(repeating: 32, count: 4097)))
    }

    func testWireControlsDecodeIntoRequiredTypedPayloads() throws {
        let selection = try ControlMessage.decode(Data(#"{"type":"select","device":"abcdefab-1111-2222-3333-abcdefabcdef"}"#.utf8))
        guard case .select(let device) = selection else { return XCTFail("Expected selection") }
        XCTAssertEqual(device, "ABCDEFAB-1111-2222-3333-ABCDEFABCDEF")
        let touch = try ControlMessage.decode(Data(#"{"type":"touch","phase":"cancelled","x":0.25,"y":0.75,"rotation":90}"#.utf8))
        guard case .touch(let contact) = touch else { return XCTFail("Expected touch") }
        XCTAssertEqual(contact.phase, .cancelled)
        XCTAssertEqual(contact.point, CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(contact.orientation, .landscapeLeft)
        let key = try ControlMessage.decode(Data(#"{"type":"key","phase":"up","usage":225}"#.utf8))
        guard case .key(let event) = key else { return XCTFail("Expected key") }
        XCTAssertEqual(event, KeyEvent(phase: .up, usage: 225))
        let ack = try ControlMessage.decode(Data(#"{"type":"ack","frame":42}"#.utf8))
        guard case .ack(let frame) = ack else { return XCTFail("Expected acknowledgement") }
        XCTAssertEqual(frame, 42)
    }

    func testSelectionAndRefreshNeverBootStoppedDevices() async throws {
        let backend = MockBackend(), sink = MessageSink()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend)) { await sink.append($0) }
        await session.handle(.select(deviceA))
        await session.handle(.refresh)
        let boots = await backend.boots
        XCTAssertEqual(boots, 0)
        let state = await sink.lastState()
        XCTAssertEqual(state["status"] as? String, "stopped")
        XCTAssertEqual(state["selected"] as? String, deviceA)
        await session.close()
        let stops = await backend.stops
        XCTAssertEqual(stops, 0)
    }

    func testStartStopAndDisconnectHaveIndependentLifetimes() async throws {
        let backend = MockBackend(), sink = MessageSink()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend)) { await sink.append($0) }
        await session.handle(.select(deviceA))
        await session.handle(.start)
        await session.handle(.stop)
        let boots = await backend.boots, stops = await backend.stops
        XCTAssertEqual(boots, 1); XCTAssertEqual(stops, 1)
        let state = await sink.lastState()
        XCTAssertEqual(state["selected"] as? String, deviceA)
        XCTAssertEqual(state["status"] as? String, "stopped")
        await session.handle(.start)
        await session.close()
        let finalStops = await backend.stops, finalState = await backend.state
        XCTAssertEqual(finalStops, 1)
        XCTAssertEqual(finalState, .booted)
        XCTAssertTrue(backend.input.closed)
    }

    func testExternalShutdownDoesNotAutoRestart() async throws {
        let backend = MockBackend(state: .booted), sink = MessageSink()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend)) { await sink.append($0) }
        await session.handle(.select(deviceA))
        await backend.setState(.shutdown)
        await session.handle(.refresh)
        let boots = await backend.boots
        XCTAssertEqual(boots, 0)
        let state = await sink.lastState()
        XCTAssertEqual(state["status"] as? String, "stopped")
        await session.close()
    }

    func testBrowsersShareOneConnectionAndClosingOneDoesNotCloseDisplay() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let sinkA = MessageSink(), sinkB = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkA.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkB.append($0) }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceA))
        let count = await backend.connects
        XCTAssertEqual(count, 1)
        try await presentFrame(a, backend: backend, sink: sinkA)
        await b.streamFrame()
        let frameCount = await sinkB.frameCount
        XCTAssertEqual(frameCount, 1)
        let shared = await sinkB.lastState()
        XCTAssertEqual(shared["viewers"] as? Int, 2)
        await a.close()
        XCTAssertFalse(backend.input.closed)
        await b.handle(.key(KeyEvent(phase: .down, usage: 4)))
        XCTAssertEqual(backend.input.events.last, "key:down:4")
        await b.close()
        XCTAssertTrue(backend.input.closed)
        XCTAssertEqual(backend.input.events.last, "key:up:4")
    }

    func testTabsCanSwitchBetweenSharedAndDifferentDevices() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let sinkA = MessageSink(), sinkB = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions) { await sinkA.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions) { await sinkB.append($0) }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceB))
        await b.handle(.key(KeyEvent(phase: .down, usage: 5)))
        XCTAssertTrue(backend.input.events.isEmpty)
        XCTAssertEqual(backend.inputB.events, ["key:down:5"])
        await b.handle(.select(deviceA))
        let state = await sinkB.lastState()
        XCTAssertEqual(state["selected"] as? String, deviceA)
        XCTAssertNil(state["message"])
        XCTAssertFalse(backend.input.closed)
        XCTAssertTrue(backend.inputB.closed)
        XCTAssertEqual(backend.inputB.events.last, "key:up:5")
        await a.close()
        await b.close()
    }

    func testSharedKeysAndGesturesAreReleasedOnlyByTheirOwner() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let sink = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sink.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions) { _ in }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceA))
        try await presentFrame(a, backend: backend, sink: sink)
        await a.handle(.key(KeyEvent(phase: .down, usage: 225)))
        await b.handle(.key(KeyEvent(phase: .down, usage: 225)))
        await a.handle(.touch(.init(phase: .began, point: CGPoint(x: 0.2, y: 0.3), orientation: .portrait)))
        await b.handle(.touch(.init(phase: .began, point: CGPoint(x: 0.8, y: 0.9), orientation: .portrait)))
        await b.handle(.release)
        XCTAssertEqual(backend.input.events, ["key:down:225", "touch:began"])
        await a.close()
        XCTAssertEqual(backend.input.events.suffix(2), ["touch:cancelled", "key:up:225"])
        XCTAssertFalse(backend.input.closed)
        await b.close()
    }

    func testSharedStartStopAndRotationReachOtherTabsWithoutPolling() async throws {
        let backend = MockBackend(), sessions = DeviceSessions(backend: backend)
        let sinkA = MessageSink(), sinkB = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkA.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkB.append($0) }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceA))
        async let startA: Void = a.handle(.start)
        async let startB: Void = b.handle(.start)
        _ = await (startA, startB)
        let boots = await backend.boots, connections = await backend.connects
        XCTAssertEqual(boots, 1); XCTAssertEqual(connections, 1)
        try await presentFrame(a, backend: backend, sink: sinkA)
        await b.streamFrame()
        await a.handle(.rotate)
        await a.handle(.refresh)
        await b.streamFrame()
        let rotated = await sinkB.lastState()
        XCTAssertEqual(rotated["rotation"] as? Int, 90)
        await b.handle(.stop)
        await a.streamFrame()
        let stopped = await sinkA.lastState()
        XCTAssertEqual(stopped["status"] as? String, "stopped")
        await a.close(); await b.close()
    }

    func testSlowBrowserDoesNotBlockAnotherBrowsersFrames() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let sinkA = MessageSink(), sinkB = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkA.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkB.append($0) }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceA))
        try await presentFrame(a, backend: backend, sink: sinkA)
        await b.streamFrame()
        await b.handle(.ack(1))
        await b.handle(.rotate)
        await a.streamFrame(); await b.streamFrame()
        let countA = await sinkA.frameCount, countB = await sinkB.frameCount
        XCTAssertEqual(countA, 1); XCTAssertEqual(countB, 2)
        await a.close(); await b.close()
    }

    func testConcurrentRotationsAreOrderedAcrossBackendSuspension() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        await backend.delayRotations()
        let shared = await sessions.device(deviceA), a = UUID(), b = UUID()
        try await shared.attach(a, start: false)
        try await shared.attach(b, start: false)
        async let turnA: Void = shared.control(.rotate, owner: a)
        async let turnB: Void = shared.control(.rotate, owner: b)
        _ = try await (turnA, turnB)
        let rotated = await shared.snapshot()
        XCTAssertEqual(rotated.orientation, .portraitUpsideDown)
        await shared.detach(a); await shared.detach(b)
    }

    func testUnacknowledgedBrowserDetachesOnlyItselfAndCanRetry() async throws {
        let backend = MockBackend(state: .booted), sessions = DeviceSessions(backend: backend)
        let sinkA = MessageSink(), sinkB = MessageSink()
        let a = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder(), frameTimeout: 0) { await sinkA.append($0) }
        let b = SimulatorSession(backend: backend, sessions: sessions, encoder: FakeEncoder()) { await sinkB.append($0) }
        await a.handle(.select(deviceA))
        await b.handle(.select(deviceA))
        try await presentFrame(a, backend: backend, sink: sinkA)
        await b.streamFrame()
        await a.streamFrame()
        let failed = await sinkA.lastState()
        XCTAssertEqual(failed["status"] as? String, "unavailable")
        XCTAssertFalse(backend.input.closed)
        await b.handle(.ack(1))
        await b.handle(.rotate)
        await b.streamFrame()
        let frames = await sinkB.frameCount
        XCTAssertEqual(frames, 2)
        await a.handle(.refresh)
        let retried = await sinkA.lastState(), connections = await backend.connects
        XCTAssertEqual(retried["status"] as? String, "running")
        XCTAssertEqual(connections, 1)
        await a.close(); await b.close()
    }

    func testInputIsReleasedOnDisconnectAndAfterRotation() async throws {
        let backend = MockBackend(state: .booted), sink = MessageSink()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend), encoder: FakeEncoder()) { await sink.append($0) }
        await session.handle(.select(deviceA))
        try await presentFrame(session, backend: backend, sink: sink)
        await session.handle(.key(KeyEvent(phase: .down, usage: 0xe1)))
        await session.handle(.touch(.init(phase: .began, point: CGPoint(x: 0.25, y: 0.75), orientation: .portrait)))
        await session.handle(.rotate)
        XCTAssertEqual(backend.input.events.suffix(2), ["touch:cancelled", "key:up:225"])
        await session.handle(.touch(.init(phase: .began, point: CGPoint(x: 0.25, y: 0.75), orientation: .landscapeLeft)))
        XCTAssertEqual(backend.input.lastPoint, CGPoint(x: 0.75, y: 0.75))
        await session.close()
        XCTAssertEqual(backend.input.events.last, "touch:cancelled")
    }

    func testFrameBackpressureRequiresMatchingAcknowledgement() async throws {
        let backend = MockBackend(state: .booted), sink = MessageSink()
        let session = SimulatorSession(backend: backend, sessions: DeviceSessions(backend: backend), encoder: FakeEncoder()) { await sink.append($0) }
        await session.handle(.select(deviceA))
        try await presentFrame(session, backend: backend, sink: sink)
        backend.display.push()
        for _ in 0..<10 { await Task.yield() }
        await session.streamFrame()
        let countA = await sink.frameCount
        XCTAssertEqual(countA, 1)
        await session.handle(.ack(999))
        await session.streamFrame()
        let countB = await sink.frameCount
        XCTAssertEqual(countB, 1)
        await session.handle(.ack(1))
        await session.streamFrame()
        let countC = await sink.frameCount
        XCTAssertEqual(countC, 2)
        await session.close()
    }

    func testJPEGEncodingRotatesAndBoundsDimensions() throws {
        let frame = DisplayFrame(surface: MockDisplay.makeSurface(width: 100, height: 200))
        let data = try JPEGFrameEncoder().encode(frame, orientation: .landscapeLeft)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 100)
        let large = DisplayFrame(surface: MockDisplay.makeSurface(width: 2000, height: 1000))
        let bounded = try JPEGFrameEncoder().encode(large, orientation: .portrait)
        let boundedSource = try XCTUnwrap(CGImageSourceCreateWithData(bounded as CFData, nil))
        let boundedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(boundedSource, 0, nil))
        XCTAssertEqual(boundedImage.width, 1280); XCTAssertEqual(boundedImage.height, 640)
    }

    func testServerShutdownReleasesHeldInputWithoutStoppingDevice() async throws {
        var options = try ServerOptions(arguments: ["serve"]); options.port = 0
        let backend = MockBackend(state: .booted), server = SimulatorServer(options: options, backend: backend)
        let port = try await server.start()
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws?token=\(options.token)")!)
        socket.resume()
        _ = try await socket.receive()
        try await socket.send(.string("{\"type\":\"select\",\"device\":\"\(deviceA)\"}"))
        _ = try await socket.receive()
        _ = try await socket.receive()
        try await socket.send(.string(#"{"type":"key","phase":"down","usage":225}"#))
        for _ in 0..<100 where backend.input.events.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.input.events, ["key:down:225"])
        await server.shutdown()
        socket.cancel(with: .normalClosure, reason: nil)
        XCTAssertEqual(backend.input.events, ["key:down:225", "key:up:225"])
        XCTAssertTrue(backend.input.closed)
        let stops = await backend.stops
        XCTAssertEqual(stops, 0)
    }

    func testHTTPAndWebSocketWorkWithoutDesktopApp() async throws {
        var options = try ServerOptions(arguments: ["serve"]); options.port = 0
        let backend = MockBackend(), server = SimulatorServer(options: options, backend: backend)
        let port = try await server.start()
        let (page, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Muxify Simulator"))
        let (_, unauthorized) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/ws?token=bad")!)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws?token=\(options.token)")!)
        socket.resume()
        let first = try await socket.receive()
        guard case .string(let initial) = first else { return XCTFail("Expected initial Device state") }
        XCTAssertTrue(initial.contains("choosing"))
        try await socket.send(.string("{\"type\":\"select\",\"device\":\"\(deviceA)\"}"))
        guard case .string(let selected) = try await socket.receive() else { return XCTFail("Expected selected Device state") }
        XCTAssertTrue(selected.contains("stopped"))
        socket.cancel(with: .normalClosure, reason: nil)
        await server.shutdown()
        let boots = await backend.boots
        XCTAssertEqual(boots, 0)
    }

    private func presentFrame(_ session: SimulatorSession, backend: MockBackend, sink: MessageSink) async throws {
        backend.display.push()
        for _ in 0..<100 {
            await Task.yield()
            await session.streamFrame()
            if await sink.frameCount > 0 { return }
        }
        XCTFail("Did not receive a frame")
    }
}

private actor MessageSink {
    private var messages: [ServerMessage] = []
    func append(_ message: ServerMessage) { messages.append(message) }
    var frameCount: Int { messages.filter { if case .frame = $0 { return true }; return false }.count }
    func lastState() -> [String: Any] {
        for message in messages.reversed() {
            if case .text(let data) = message, let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return state }
        }
        return [:]
    }
}

private struct FakeEncoder: FrameEncoding {
    func encode(_ frame: DisplayFrame, orientation: DeviceOrientation) throws -> Data { Data([0xff,0xd8,0xff,0xd9]) }
}

actor MockBackend: SimulatorBackendProtocol {
    var state: DeviceState
    var stateB: DeviceState
    var boots = 0, stops = 0, connects = 0
    var rotation: DeviceOrientation = .portrait
    var rotationDelay = false
    private nonisolated let connectionA = MockConnection()
    private nonisolated let connectionB = MockConnection()
    nonisolated var display: MockDisplay { connectionA.current.display }
    nonisolated var input: MockInput { connectionA.current.input }
    nonisolated var displayB: MockDisplay { connectionB.current.display }
    nonisolated var inputB: MockInput { connectionB.current.input }
    init(state: DeviceState = .shutdown) { self.state = state; stateB = state }
    func setState(_ state: DeviceState) { self.state = state }
    func delayRotations() { rotationDelay = true }
    func devices() -> [DeviceInfo] {
        [deviceA, deviceB].map { DeviceInfo(udid: $0, name: "Test iPhone", deviceTypeIdentifier: "iPhone",
            runtimeName: "iOS 26", state: $0 == deviceA ? state : stateB, isAvailable: true) }
    }
    func connect(udid: String, startIfNeeded: Bool) throws -> SimulatorConnection {
        if (udid == deviceA ? state : stateB) == .shutdown {
            guard startIfNeeded else { throw SimulatorError.stopped }
            boots += 1
            if udid == deviceA { state = .booted } else { stateB = .booted }
        }
        connects += 1
        let pair = (udid == deviceA ? connectionA : connectionB).open()
        return SimulatorConnection(udid: udid, display: pair.display, input: pair.input, orientation: .portrait)
    }
    func rotate(udid: String, to orientation: DeviceOrientation) async throws -> DeviceOrientation {
        if rotationDelay { try await Task.sleep(for: .milliseconds(25)) }
        rotation = orientation
        return rotation
    }
    func stop(udid: String) { stops += 1; if udid == deviceA { state = .shutdown } else { stateB = .shutdown } }
    func forget(udid: String) {}
}

/// Closed streams cannot be reopened. A reconnect gets fresh resources, like CoreSimulator.
private final class MockConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var pair = (display: MockDisplay(), input: MockInput())
    var current: (display: MockDisplay, input: MockInput) {
        lock.lock(); defer { lock.unlock() }
        return pair
    }
    func open() -> (display: MockDisplay, input: MockInput) {
        lock.lock(); defer { lock.unlock() }
        if pair.input.closed { pair = (MockDisplay(), MockInput()) }
        return pair
    }
}

final class MockDisplay: DisplaySession, @unchecked Sendable {
    let frames: AsyncStream<DisplayFrame>
    private let continuation: AsyncStream<DisplayFrame>.Continuation
    init() { (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func push() { continuation.yield(DisplayFrame(surface: Self.makeSurface())) }
    func close() { continuation.finish() }
    static func makeSurface(width: Int = 4, height: Int = 8) -> IOSurfaceRef {
        IOSurfaceCreate([kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: width * 4, kIOSurfacePixelFormat: 0x42475241] as CFDictionary)!
    }
}

final class MockInput: InputSession, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var point: CGPoint?
    private var isClosed = false
    var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var lastPoint: CGPoint? { lock.lock(); defer { lock.unlock() }; return point }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    private func record(_ text: String, point: CGPoint? = nil) { lock.lock(); defer { lock.unlock() }; log.append(text); if let point { self.point = point } }
    func touch(_ event: TouchEvent) async throws { record("touch:\(event.phase)", point: event.point) }
    func key(_ event: KeyEvent) async throws { record("key:\(event.phase):\(event.usage)") }
    func home(phase: KeyEvent.Phase) async throws { record("button:home:\(phase)") }
    func close() { lock.lock(); isClosed = true; lock.unlock() }
}
