import Foundation

/// Device access shared by browser connections, independent of the desktop app.
protocol SimulatorBackendProtocol: Sendable {
    func devices() async throws -> [DeviceInfo]
    func connect(udid: String, startIfNeeded: Bool) async throws -> SimulatorConnection
    func rotate(udid: String, to orientation: DeviceOrientation) async throws -> DeviceOrientation
    func stop(udid: String) async throws
    func forget(udid: String) async
}

actor SimulatorBackend: SimulatorBackendProtocol {
    private var adapter: CoreSimulator?

    private func load() throws -> CoreSimulator {
        if let adapter { return adapter }
        let loaded = try CoreSimulator(xcode: XcodeInstallation.locate())
        adapter = loaded
        return loaded
    }

    func devices() throws -> [DeviceInfo] {
        try load().devices().filter {
            $0.isAvailable && ($0.deviceTypeIdentifier.contains("iPhone") || $0.deviceTypeIdentifier.contains("iPad"))
        }.sorted {
            if $0.name == $1.name { return $0.runtimeName > $1.runtimeName }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func connect(udid: String, startIfNeeded: Bool) async throws -> SimulatorConnection {
        try Task.checkCancellation()
        let adapter = try load()
        guard let device = try adapter.devices().first(where: { $0.udid == udid }), device.isAvailable else {
            throw SimulatorError.message("The selected Device is unavailable. Choose another Device from the menu.")
        }
        guard device.state == .booted || device.state == .booting || startIfNeeded else {
            throw SimulatorError.stopped
        }
        if device.state != .booted {
            let tools = SimctlService()
            if device.state == .shutdown, startIfNeeded { try await tools.boot(udid: udid) }
            try await tools.waitForBoot(udid: udid)
        }
        try Task.checkCancellation()
        guard try adapter.devices().first(where: { $0.udid == udid })?.state == .booted else {
            throw SimulatorError.stopped
        }
        let display = try adapter.openDisplay(udid)
        do {
            // Resolve the cached connection synchronously on this actor before
            // awaiting XPC; cache access must not escape to the async executor.
            let report = try await adapter.displayInfo(udid).report()
            guard let active = report.activeIntegrated else {
                throw SimulatorError.message("Simulator did not identify one active built-in display.")
            }
            // Device Hub activates the screen-addressed digitizer on ordinary iPhones/iPads too.
            // The guest silently drops legacy HID while modern input is active.
            let input = try adapter.openInput(udid, screenID: active.displayID)
            do {
                try adapter.setHardwareKeyboardEnabled(true, udid: udid)
                let rotation = DeviceOrientation.fromDegrees(active.currentRotation)
                try Task.checkCancellation()
                return SimulatorConnection(udid: udid, display: display, input: input,
                                           orientation: rotation)
            } catch {
                input.close()
                throw error
            }
        } catch {
            display.close()
            throw error
        }
    }

    func rotate(udid: String, to orientation: DeviceOrientation) async throws -> DeviceOrientation {
        let adapter = try load()
        try adapter.setOrientation(orientation, udid: udid)
        // This is physical display orientation, not the app's supported interface orientation.
        // SpringBoard and portrait-only apps may keep drawing portrait content after a turn.
        // Waiting for currentRotation to match would silently undo rotation in those apps.
        return orientation
    }

    func stop(udid: String) async throws {
        try await SimctlService().shutdown(udid: udid)
    }

    func forget(udid: String) { adapter?.forgetConnections(udid) }
}

struct SimulatorConnection: Sendable {
    let udid: String
    let display: any DisplaySession
    let input: any InputSession
    let orientation: DeviceOrientation
}

enum SimulatorError: Error, LocalizedError, Equatable {
    case stopped
    case message(String)

    var errorDescription: String? {
        switch self {
        case .stopped: return "Device is stopped. Choose Start Device to start it."
        case .message(let text): return text
        }
    }
}

extension DeviceOrientation {
    static func fromDegrees(_ degrees: Int) -> DeviceOrientation {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .landscapeLeft
        case 180: return .portraitUpsideDown
        case 270: return .landscapeRight
        default: return .portrait
        }
    }
}
