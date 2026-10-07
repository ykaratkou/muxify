import Darwin
import Foundation
import XCTest
@testable import MuxifyCLI

final class CLIIntegrationTests: XCTestCase {
    func testShortLivedProcessesCanBeAwaitedRepeatedly() async throws {
        for _ in 0..<10 {
            for (executable, status) in [("/usr/bin/true", Int32(0)), ("/usr/bin/false", Int32(1))] {
                let process = makeProcess(URL(fileURLWithPath: executable), arguments: [], output: Pipe())
                try process.run()
                defer { stopIfRunning(process) }
                try await waitForExit(process)
                XCTAssertEqual(process.terminationStatus, status)
            }
        }
    }

    func testSubprocessWaitTimesOutAndCleanupKillsProcess() async throws {
        let process = makeProcess(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], output: Pipe())
        try process.run()
        defer { stopIfRunning(process) }
        let start = Date()
        do {
            try await waitForExit(process, timeout: 0.05)
            XCTFail("Expected subprocess wait to time out")
        } catch {
            XCTAssertEqual(error.localizedDescription, "CLI did not exit before the timeout")
        }
        XCTAssertTrue(process.isRunning)
        stopIfRunning(process)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRelocatedBinaryAndInstalledSymlinkSupportHelpAndValidation() async throws {
        let tool = try standaloneCLI()
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let link = tool.deletingLastPathComponent().appendingPathComponent("installed-muxify")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        for executable in [tool, link] {
            for arguments in [["--help"], ["simulator", "--help"], ["simulator", "serve", "--help"]] {
                let result = try await run(executable, arguments: arguments)
                XCTAssertEqual(result.status, 0, result.output)
                XCTAssertTrue(result.output.contains("muxify simulator serve"))
            }
            let unknown = try await run(executable, arguments: ["unknown"])
            XCTAssertEqual(unknown.status, 2)
            let invalidPort = try await run(executable, arguments: ["simulator", "serve", "--port", "0"])
            XCTAssertEqual(invalidPort.status, 1)
            XCTAssertTrue(invalidPort.output.contains("muxify simulator: --port requires"))
        }
    }

    func testRelocatedBinaryServesEmbeddedPageAndShutsDownWithoutHelper() async throws {
        let tool = try standaloneCLI()
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        let port = try availablePort()
        let output = Pipe()
        let process = makeProcess(tool, arguments: ["simulator", "serve", "--port", String(port)], output: output)
        try process.run()
        defer { stopIfRunning(process) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        var page: String?
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            if let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                page = String(decoding: data, as: UTF8.self)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(try XCTUnwrap(page).contains("Muxify Simulator"))
        process.terminate()
        try await waitForExit(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("http://127.0.0.1:\(port)/#token="))
    }

    private func standaloneCLI() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/cli-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("muxify")
        try FileManager.default.copyItem(at: binary, to: tool)
        // No muxify-simulator, resource bundle, desktop app, or web assets accompany it.
        return tool
    }

    private func makeProcess(_ tool: URL, arguments: [String], output: Pipe) -> Process {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = tool.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin"
        environment.removeValue(forKey: "TMUX_PANE")
        environment.removeValue(forKey: "MUXIFY_SIMULATOR_TOKEN")
        environment["MUXIFY_SIMULATOR_SERVER"] = "/no-external-server"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        return process
    }

    private func run(_ tool: URL, arguments: [String]) async throws -> CLICommandResult {
        let output = Pipe()
        let process = makeProcess(tool, arguments: arguments, output: output)
        try process.run()
        defer { stopIfRunning(process) }
        try await waitForExit(process)
        return CLICommandResult(status: process.terminationStatus,
                                output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !process.isRunning else { throw CLIError("CLI did not exit before the timeout") }
        // Async tasks can resume on a different thread than Process.run().
        // waitUntilExit() can then hang in a thread-local run loop even after exit.
        // Once isRunning is false, terminationStatus is already available.
    }

    private func stopIfRunning(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertFalse(process.isRunning, "CLI did not exit after SIGKILL")
        }
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CLIError("Could not create test socket") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard Darwin.bind(descriptor, socketAddress, size) == 0 else { return Int32(-1) }
                return getsockname(descriptor, socketAddress, &size)
            }
        }
        guard status == 0 else { throw CLIError("Could not reserve a test port") }
        return UInt16(bigEndian: address.sin_port)
    }
}
