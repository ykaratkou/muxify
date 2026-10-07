import Foundation

/// Only explicit Device lifecycle operations; discovery/display/input use CoreSimulator.
struct SimctlService: Sendable {
    static func bootArguments(udid: String) -> [String] { ["simctl", "boot", udid] }
    static func shutdownArguments(udid: String) -> [String] { ["simctl", "shutdown", udid] }
    // Never pass -b: waiting must not restart an externally stopped Device.
    static func bootStatusArguments(udid: String) -> [String] { ["simctl", "bootstatus", udid] }

    func boot(udid: String) async throws {
        let args = Self.bootArguments(udid: udid)
        let result = try await ProcessRunner.runAsync("/usr/bin/xcrun", args)
        if result.status != 0, !result.standardError.contains("current state: Booted") {
            throw CoreSimulatorError.simctl(args: Array(args.dropFirst()), code: result.status, stderr: result.standardError)
        }
    }

    func shutdown(udid: String) async throws {
        let args = Self.shutdownArguments(udid: udid)
        let result = try await ProcessRunner.runAsync("/usr/bin/xcrun", args)
        if result.status != 0, !result.standardError.contains("current state: Shutdown") {
            throw CoreSimulatorError.simctl(args: Array(args.dropFirst()), code: result.status, stderr: result.standardError)
        }
    }

    func waitForBoot(udid: String) async throws {
        let args = Self.bootStatusArguments(udid: udid)
        let result = try await ProcessRunner.runAsync("/usr/bin/xcrun", args, timeout: 120)
        guard result.status == 0 else {
            throw CoreSimulatorError.simctl(args: Array(args.dropFirst()), code: result.status, stderr: result.standardError)
        }
    }
}
