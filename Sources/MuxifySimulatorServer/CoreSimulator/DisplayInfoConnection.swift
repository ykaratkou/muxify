import Foundation
import XPC

/// One cached connection per Device: repeatedly reconnecting to the guest's
/// CoreDevice service can leave it unable to answer subsequent display queries.
final class DisplayInfoConnection: @unchecked Sendable {
    static let serviceName = "com.apple.coredevice.feature.getdisplayinfo"
    private static let action = "com.apple.coredevice.action.displayinfo"
    private let connection: xpc_connection_t
    private let udid: String
    private let queue = DispatchQueue(label: "dev.muxify.simulator.display-info", qos: .userInitiated)

    init(port: mach_port_t, udid: String) throws {
        self.udid = udid
        connection = try SimulatorXPC.connect(port: port, queue: queue)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
    }

    deinit { xpc_connection_cancel(connection) }

    func report() async throws -> DisplayReport {
        let reply = try await SimulatorXPC.request(connection, message: request(), queue: queue)
        if let failure = xpc_dictionary_get_value(reply, "CoreDevice.error") {
            let domain = XPCValue.string(failure, "domain") ?? "unknown"
            let code = Int(XPCValue.number(failure, "code") ?? 0)
            throw CoreSimulatorError.privateCall(symbol: Self.action, message: "the Device answered \(domain) (\(code))")
        }
        guard let output = XPCValue.dictionary(reply, "CoreDevice.output") else {
            throw CoreSimulatorError.privateCall(symbol: Self.action, message: "the Device answered without an output")
        }
        return try DisplayReport.parse(output)
    }

    private func request() throws -> xpc_object_t {
        let bundle = Bundle(url: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework"))
        guard let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw CoreSimulatorError.capabilityUnavailable(name: "CoreDevice framework version")
        }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt64($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else {
            throw CoreSimulatorError.privateCall(symbol: "CFBundleVersion", message: "unreadable CoreDevice version \(version)")
        }
        let versionValue = xpc_dictionary_create(nil, nil, 0)
        let components = xpc_array_create(nil, 0)
        for number in numbers { xpc_array_append_value(components, xpc_uint64_create(number)) }
        xpc_dictionary_set_value(versionValue, "components", components)
        xpc_dictionary_set_int64(versionValue, "originalComponentsCount", Int64(numbers.count))
        xpc_dictionary_set_string(versionValue, "stringValue", version)

        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", Self.action)
        xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", udid)
        xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", UUID().uuidString)
        xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
        xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", versionValue)
        xpc_dictionary_set_value(request, "CoreDevice.input", xpc_dictionary_create(nil, nil, 0))
        return request
    }
}
