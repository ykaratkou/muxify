import Foundation
import IOSurface
import MuxifySimulatorPrivate

final class SimulatorDisplaySession: DisplaySession, @unchecked Sendable {
    let frames: AsyncStream<DisplayFrame>
    private let screen: any MuxifySimScreen
    private let token = UUID()
    private let continuation: AsyncStream<DisplayFrame>.Continuation
    private let lock = NSLock()
    private var surface: IOSurfaceRef?
    private var isClosed = false

    init(descriptor: AnyObject) throws {
        let register = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        guard let screenProtocol = NSProtocolFromString("SimScreen"),
              descriptor.conforms(to: screenProtocol), descriptor.responds(to: register) else {
            throw CoreSimulatorError.capabilityUnavailable(name: "Xcode 27 screen callbacks")
        }
        screen = unsafeBitCast(descriptor, to: (any MuxifySimScreen).self)
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let renderable = unsafeBitCast(descriptor, to: (any MuxifySimDisplayIOSurfaceRenderable).self)
        surface = Self.surface(from: renderable.framebufferSurface)
        screen.registerCallbacks(
            with: token, callbackQueue: DispatchQueue(label: "dev.muxify.simulator.display"),
            frameCallback: { [weak self] in self?.emitCurrentFrame() },
            surfacesChangedCallback: { [weak self] primary, _ in
                guard let self else { return }
                lock.lock()
                surface = Self.surface(from: primary)
                lock.unlock()
                emitCurrentFrame()
            },
            propertiesChangedCallback: { _ in }
        )
        emitCurrentFrame()
    }

    deinit { close() }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        screen.unregisterScreenCallbacks(with: token)
        continuation.finish()
    }

    private func emitCurrentFrame() {
        lock.lock()
        let current = surface
        let closed = isClosed
        lock.unlock()
        // Always stream the raw framebuffer; the browser draws its own frame.
        guard !closed, let current else { return }
        continuation.yield(DisplayFrame(surface: current))
    }

    private static func surface(from value: Any?) -> IOSurfaceRef? {
        guard let value, CFGetTypeID(value as AnyObject) == IOSurfaceGetTypeID() else { return nil }
        return unsafeBitCast(value as AnyObject, to: IOSurfaceRef.self)
    }
}
