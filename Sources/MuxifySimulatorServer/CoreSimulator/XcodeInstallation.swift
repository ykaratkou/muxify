import Foundation

struct XcodeInstallation {
    let developerDir: URL

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> XcodeInstallation {
        let path: String
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty {
            path = override
        } else {
            let selected = try ProcessRunner.run("/usr/bin/xcode-select", ["-p"])
            guard selected.status == 0 else {
                throw CoreSimulatorError.xcodeNotFound(searched: ["$DEVELOPER_DIR", "xcode-select -p"])
            }
            path = selected.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw CoreSimulatorError.xcodeNotFound(searched: [path])
        }
        let result = try ProcessRunner.run("/usr/bin/xcodebuild", ["-version"])
        guard result.status == 0,
              let version = result.standardOutput.split(separator: "\n").first(where: { $0.hasPrefix("Xcode ") }),
              let major = Int(version.dropFirst(6).split(separator: ".").first.map(String.init) ?? "") else {
            throw CoreSimulatorError.xcodeVersionUnreadable(output: result.standardOutput + result.standardError)
        }
        guard major >= 27 else {
            throw SimulatorError.message("Simulator requires Xcode 27 or later. Select a full Xcode installation with xcode-select.")
        }
        return XcodeInstallation(developerDir: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }

    func loadCoreSimulator() throws {
        _ = try load("CoreSimulator", paths: [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            developerDir.appending(path: "Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator").path,
        ])
    }

    func loadSimulatorKit() throws -> UnsafeMutableRawPointer {
        let appRoot = developerDir.deletingLastPathComponent().deletingLastPathComponent()
        return try load("SimulatorKit", paths: [
            appRoot.appending(path: "Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit").path,
            developerDir.appending(path: "Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit").path,
        ])
    }

    // Frameworks remain loaded for the process lifetime: Objective-C proxies and
    // their callbacks may outlive the initiating call.
    private func load(_ name: String, paths: [String]) throws -> UnsafeMutableRawPointer {
        var attempts: [String] = []
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                attempts.append("\(path) (not present)")
                continue
            }
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { return handle }
            attempts.append("\(path) (\(dlerror().map { String(cString: $0) } ?? "dlopen failed"))")
        }
        throw CoreSimulatorError.frameworkNotFound(name: name, searched: attempts)
    }
}
