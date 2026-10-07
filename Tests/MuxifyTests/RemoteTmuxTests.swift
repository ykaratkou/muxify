import XCTest
import Darwin

/// Executes the real remote shell protocol against an isolated tmux socket.
/// No network, default tmux server, user config or real HOME is touched.
final class RemoteTmuxTests: XCTestCase {
    func testBootstrapClientTargetingLiteralArgumentsAndServerRestart() throws {
        guard let tmux = Tmux.binary else { throw XCTSkip("tmux is needed for the isolated transport integration test") }
        let root = try TestDirectory()
        defer { withExtendedLifetime(root) {} }
        let fm = FileManager.default
        let home = root.url.appendingPathComponent("home")
        let bin = root.url.appendingPathComponent("bin")
        let socket = root.url.appendingPathComponent("t").path
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("tmux")
        try ("#!/bin/sh\nexec " + Tmux.shellQuote(tmux) + " -S " + Tmux.shellQuote(socket) + " -f /dev/null \"$@\"\n")
            .write(to: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["LC_ALL"] = "C"
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["SSH_TTY"] = nil
        let runner = CommandRunner()
        func raw(_ args: [String]) throws -> String {
            try runner.run(CommandInvocation(executable: shim.path, arguments: ["-u"] + args), environment: environment)
        }
        defer { _ = try? raw(["kill-server"]) }
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "test", host: "unused", username: "unused"),
                                temporaryDirectory: root.url)
        func remote(_ args: [String]) throws -> String {
            try runner.run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", ssh.command(args).arguments.last!]),
                           environment: environment)
        }
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = ["-q", "/dev/null", "/bin/sh", "-c", ssh.bootstrap()]
        terminal.environment = environment
        let log = root.url.appendingPathComponent("terminal.log")
        fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let terminalInput = Pipe()
        terminal.standardInput = terminalInput
        terminal.standardOutput = output
        terminal.standardError = output
        try terminal.run()
        defer { stop(terminal) }

        var marker: [String] = []
        var snapshot: TmuxSnapshot?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            marker = ((try? remote(["show-option", "-sqv", ssh.markerOption])) ?? "")
                .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
            snapshot = try? Tmux.readSnapshot(using: remote)
            if marker.count == 4, let pid = Int(marker[0]),
               snapshot?.clients.contains(where: { $0.pid == pid && $0.tty == marker[1] && !$0.isControl }) == true { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(marker.count, 4, (try? String(contentsOf: log, encoding: .utf8)) ?? "No terminal output")
        guard marker.count == 4 else { return }
        let initial = try XCTUnwrap(snapshot)
        let own = try XCTUnwrap(initial.clients.first { $0.pid == Int(marker[0]) && $0.tty == marker[1] })
        let features = try remote(["list-clients", "-F", "#{client_tty} #{client_termfeatures}"])
        let ownFeatures = try XCTUnwrap(features.split(separator: "\n").first { $0.hasPrefix(own.tty + " ") })
        XCTAssertTrue(ownFeatures.split(separator: " ").last?.split(separator: ",").contains("RGB") == true)
        XCTAssertEqual(marker[2], home.path)
        XCTAssertEqual(initial.windows.first?.sessionName, "main")
        let paneDirectory = try XCTUnwrap(initial.windows.first?.path)
        XCTAssertEqual(URL(fileURLWithPath: paneDirectory).resolvingSymlinksInPath().path, home.resolvingSymlinksInPath().path)

        let otherSession = try raw(["new-session", "-d", "-s", "other", "-P", "-F", "#{session_id}", "-c", home.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let other = Process()
        other.executableURL = URL(fileURLWithPath: tmux)
        other.arguments = ["-S", socket, "-u", "-C", "attach-session", "-f", "read-only,no-output,ignore-size", "-t", otherSession]
        other.environment = environment
        let otherInput = Pipe()
        other.standardInput = otherInput
        other.standardOutput = FileHandle.nullDevice
        other.standardError = FileHandle.nullDevice
        try other.run()
        defer { stop(other) }
        let otherDeadline = Date().addingTimeInterval(3)
        while Date() < otherDeadline {
            if (try? Tmux.readSnapshot(using: remote).clients.contains { $0.pid == Int(other.processIdentifier) }) == true { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let name = "quotes ' ; $(echo wrong) 😃"
        let window = try remote(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(own.sessionID):", "-n", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try remote(["switch-client", "-c", own.tty, "-t", "\(own.sessionID):\(window)"])
        let updated = try Tmux.readSnapshot(using: remote)
        XCTAssertEqual(updated.windows.first { $0.id == window }?.name, name)
        XCTAssertEqual(updated.clients.first { $0.pid == own.pid }?.windowID, window)
        XCTAssertEqual(updated.clients.first { $0.pid == Int(other.processIdentifier) }?.sessionID, otherSession)
        XCTAssertTrue(updated.clients.first { $0.pid == Int(other.processIdentifier) }?.isControl == true)
        XCTAssertEqual(try remote(["display-message", "-p", "-t", window, "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), window)

        stop(terminal)
        XCTAssertNoThrow(try raw(["has-session", "-t", "=main"]))
        XCTAssertThrowsError(try remote(["switch-client", "-c", own.tty, "-t", otherSession]))
        XCTAssertEqual(try Tmux.readSnapshot(using: remote).clients.first { $0.pid == Int(other.processIdentifier) }?.sessionID, otherSession)

        _ = try raw(["kill-server"])
        _ = try raw(["new-session", "-d", "-s", "replacement", "-c", home.path])
        XCTAssertThrowsError(try remote(["rename-window", "-t", "@0", "wrong-server"]))
        XCTAssertNotEqual(try raw(["display-message", "-p", "-t", "@0", "#{window_name}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), "wrong-server")
        withExtendedLifetime((terminalInput, otherInput)) {}
    }

    func testMissingMasterCannotFallBackToAnIndependentSshConnection() throws {
        let root = try TestDirectory()
        defer { withExtendedLifetime(root) {} }
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "missing", host: "127.0.0.1", username: "unused"),
                                temporaryDirectory: root.url)
        // ProxyCommand=false exits locally before any SSH handshake/authentication.
        XCTAssertThrowsError(try CommandRunner().run(ssh.command(["list-sessions"]), timeout: 3)) {
            guard case .failed(let status, _) = $0 as? TmuxError else { return XCTFail("Expected fail-closed SSH, got \($0)") }
            XCTAssertEqual(status, 255)
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
