import Darwin
import Foundation
import MuxifySimulatorPrivate

/// Owned exclusively by the SimulatorBackend actor. Display and input callbacks
/// synchronize their own state; CoreSimulator calls never run concurrently here.
final class CoreSimulator {
    private let context: any MuxifySimServiceContext
    private let simulatorKit: UnsafeMutableRawPointer
    private var displayConnections: [String: DisplayInfoConnection] = [:]

    init(xcode: XcodeInstallation) throws {
        try xcode.loadCoreSimulator()
        simulatorKit = try xcode.loadSimulatorKit()
        context = try Self.makeServiceContext(developerDir: xcode.developerDir.path)
    }

    func devices() throws -> [DeviceInfo] {
        try deviceSet().devices?.compactMap { element in
            let device = unsafeBitCast(element as AnyObject, to: (any MuxifySimDevice).self)
            guard let udid = device.udid?.uuidString else { return nil }
            return DeviceInfo(
                udid: udid, name: device.name ?? udid,
                deviceTypeIdentifier: device.deviceType?.identifier ?? "",
                runtimeName: device.runtime?.name ?? RuntimeIdentifier.readableName(for: device.runtimeIdentifier ?? ""),
                state: DeviceState.from(state: device.state, stateString: device.stateString ?? ""),
                isAvailable: device.available
            )
        } ?? []
    }

    func openDisplay(_ udid: String) throws -> any DisplaySession {
        let device = try bootedDevice(udid)
        guard let io = device.io,
              let renderableProtocol = NSProtocolFromString("SimDisplayRenderable"),
              let surfaceProtocol = NSProtocolFromString("SimDisplayIOSurfaceRenderable"),
              let stateProtocol = NSProtocolFromString("SimDisplayDescriptorState") else {
            throw CoreSimulatorError.capabilityUnavailable(name: "Device display interfaces")
        }
        let ports = unsafeBitCast(io as AnyObject, to: (any MuxifySimDeviceIO).self).ioPorts ?? []
        var displays: [(descriptor: AnyObject, size: CGSize)] = []
        for element in ports {
            let port = unsafeBitCast(element as AnyObject, to: (any MuxifySimDeviceIOPort).self)
            guard let descriptor = port.descriptor as AnyObject?,
                  descriptor.conforms(to: renderableProtocol), descriptor.conforms(to: surfaceProtocol),
                  let state = unsafeBitCast(descriptor, to: (any MuxifySimDeviceIOPortDescriptor).self).state as AnyObject?,
                  state.conforms(to: stateProtocol),
                  unsafeBitCast(state, to: (any MuxifySimDisplayDescriptorState).self).displayClass == 0 else { continue }
            let size = unsafeBitCast(descriptor, to: (any MuxifySimDisplayRenderable).self).displaySize
            displays.append((descriptor, size))
        }
        guard let chosen = displays.first(where: { $0.size == device.deviceType?.mainScreenSize }) ?? displays.first else {
            throw CoreSimulatorError.capabilityUnavailable(name: "built-in display")
        }
        return try SimulatorDisplaySession(descriptor: chosen.descriptor)
    }

    func openInput(_ udid: String, screenID: Int) throws -> any InputSession {
        guard screenID > 0 else {
            throw CoreSimulatorError.capabilityUnavailable(name: "built-in display input target")
        }
        return try ScreenInputSession(port: servicePort(ScreenInputSession.serviceName, udid: udid), screenID: screenID)
    }

    func displayInfo(_ udid: String) throws -> DisplayInfoConnection {
        if let existing = displayConnections[udid] { return existing }
        let connection = try DisplayInfoConnection(port: servicePort(DisplayInfoConnection.serviceName, udid: udid), udid: udid)
        displayConnections[udid] = connection
        return connection
    }

    func forgetConnections(_ udid: String) { displayConnections[udid] = nil }

    func setHardwareKeyboardEnabled(_ enabled: Bool, udid: String) throws {
        let device = try bootedDevice(udid)
        guard (device as AnyObject).responds(to: NSSelectorFromString("setHardwareKeyboardEnabled:keyboardType:error:")),
              let symbol = dlsym(simulatorKit, "IndigoHIDGetKeyboardType") else {
            throw CoreSimulatorError.capabilityUnavailable(name: "hardware keyboard")
        }
        typealias KeyboardType = @convention(c) () -> UInt8
        do { try device.setHardwareKeyboardEnabled(enabled, keyboardType: unsafeBitCast(symbol, to: KeyboardType.self)()) }
        catch { throw CoreSimulatorError.privateCall(symbol: "setHardwareKeyboardEnabled", message: error.localizedDescription) }
    }

    func setOrientation(_ orientation: DeviceOrientation, udid: String) throws {
        let port = try servicePort(WorkspaceOrientation.portName, udid: udid)
        defer { mach_port_deallocate(mach_task_self_, port) }
        try WorkspaceOrientation.send(orientation, to: port)
    }

    private func servicePort(_ name: String, udid: String) throws -> mach_port_t {
        let device = try bootedDevice(udid)
        guard (device as AnyObject).responds(to: NSSelectorFromString("lookup:error:")) else {
            throw CoreSimulatorError.symbolNotFound(name: "-[SimDevice lookup:error:]", framework: "CoreSimulator")
        }
        let port = device.lookup(name, error: nil)
        guard port != 0 else { throw CoreSimulatorError.capabilityUnavailable(name: "\(name) on \(udid)") }
        return port
    }

    private func deviceSet() throws -> any MuxifySimDeviceSet {
        do { return try context.defaultDeviceSet() }
        catch { throw CoreSimulatorError.privateCall(symbol: "defaultDeviceSetWithError:", message: error.localizedDescription) }
    }

    private func bootedDevice(_ udid: String) throws -> any MuxifySimDevice {
        for element in try deviceSet().devices ?? [] {
            let device = unsafeBitCast(element as AnyObject, to: (any MuxifySimDevice).self)
            guard device.udid?.uuidString.caseInsensitiveCompare(udid) == .orderedSame else { continue }
            guard DeviceState.from(state: device.state, stateString: device.stateString ?? "") == .booted else {
                throw CoreSimulatorError.deviceNotBooted(udid: udid)
            }
            return device
        }
        throw CoreSimulatorError.deviceNotFound(udid: udid)
    }

    private static func makeServiceContext(developerDir: String) throws -> any MuxifySimServiceContext {
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw CoreSimulatorError.symbolNotFound(name: "SimServiceContext", framework: "CoreSimulator")
        }
        // Cast the class *object*, not the metatype: retaining a cast metatype crashes.
        let classObject = contextClass as AnyObject
        guard classObject.responds(to: NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")) else {
            throw CoreSimulatorError.symbolNotFound(name: "sharedServiceContextForDeveloperDir:error:", framework: "CoreSimulator")
        }
        let typed = unsafeBitCast(classObject, to: (any MuxifySimServiceContextClass).self)
        let context: any MuxifySimServiceContext
        do { context = try typed.sharedServiceContext(forDeveloperDir: developerDir) }
        catch { throw CoreSimulatorError.privateCall(symbol: "sharedServiceContextForDeveloperDir:error:", message: error.localizedDescription) }
        guard (context as AnyObject).responds(to: NSSelectorFromString("defaultDeviceSetWithError:")) else {
            throw CoreSimulatorError.symbolNotFound(name: "defaultDeviceSetWithError:", framework: "CoreSimulator")
        }
        return context
    }
}
