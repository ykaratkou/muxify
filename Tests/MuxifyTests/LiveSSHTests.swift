import XCTest
import Darwin

/// Opt-in smoke test of the real SSH lanes on a Linux/macOS host. Its tmux
/// server is isolated under a unique remote temp directory, not the user's.
final class LiveSSHTests: XCTestCase {
    func testRemoteAttachmentCommandsEventsAndReconnect() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MUXIFY_SSH_TEST_HOST"], let username = env["MUXIFY_SSH_TEST_USER"] else {
            throw XCTSkip("Set MUXIFY_SSH_TEST_HOST and MUXIFY_SSH_TEST_USER to test a real SSH host")
        }
        let environment = RemoteEnvironment(
            name: "Live test", host: host, username: username,
            port: env["MUXIFY_SSH_TEST_PORT"].flatMap(Int.init),
            identityFile: env["MUXIFY_SSH_TEST_IDENTITY"]
        )
        let directory = try TestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let root = "/tmp/muxify-live-" + UUID().uuidString.lowercased()
        let runner = CommandRunner()
        var rawOptions = ["-l", username,
                          "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                          "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=10"]
        if let key = environment.identityFile { rawOptions += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        if let port = environment.port { rawOptions += ["-p", String(port)] }
        func raw(_ script: String) throws -> String {
            try runner.run(CommandInvocation(executable: "/usr/bin/ssh", arguments: rawOptions + [
                "--", host, "exec /bin/sh -c " + Tmux.shellQuote(script),
            ]))
        }
        // Auth/host verification must already work without prompts for this
        // automated test. Never approve a new host key or change user setup.
        _ = try raw("mkdir -m 700 " + Tmux.shellQuote(root))
        let prefix = "export TMUX_TMPDIR=" + Tmux.shellQuote(root) + " LC_ALL=C; unset TMUX TMUX_PANE; "
        let isolatedCommand = "exec env TMUX_TMPDIR=" + Tmux.shellQuote(root) + " LC_ALL=C "
        defer {
            _ = try? raw(prefix + "tmux kill-server 2>/dev/null; "
                         + "rm -f \"$TMUX_TMPDIR/tmux-$(id -u)/default\"; "
                         + "rmdir \"$TMUX_TMPDIR/tmux-$(id -u)\" \"$TMUX_TMPDIR\"")
        }
        // Keep production SSH options and scripts intact; isolate remote tmux
        // and use a disposable TCP pipe to simulate losing just our connection.
        let proxyPIDFile = directory.url.appendingPathComponent("proxy.pid")
        let proxyScript = "printf '%%s\\n' \"$$\" > " + Tmux.shellQuote(proxyPIDFile.path)
            + "; exec /usr/bin/nc \"$0\" \"$1\""
        let proxyOption = "ProxyCommand=/bin/sh -c " + Tmux.shellQuote(proxyScript) + " %h %p"
        let shim = directory.url.appendingPathComponent("ssh")
        try """
        #!/bin/bash
        args=("$@")
        last=$((${#args[@]} - 1))
        if [[ "${args[last]}" == "exec /bin/sh -c "* ]]; then
            args[last]=\(Tmux.shellQuote(isolatedCommand))"${args[last]#exec }"
        fi
        for arg in "$@"; do
            if [[ "$arg" == "-M" ]]; then
                args=("-o" \(Tmux.shellQuote(proxyOption)) "${args[@]}")
                break
            fi
        done
        exec /usr/bin/ssh "${args[@]}"

        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        func connect() throws -> (TmuxConnection, Process, Pipe, FileHandle, URL) {
            let connection = try TmuxConnection(environment: environment, sshExecutable: shim.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", try connection.terminalCommand([])]
            var terminalEnvironment = ProcessInfo.processInfo.environment
            terminalEnvironment["TERM"] = "xterm-ghostty"
            process.environment = terminalEnvironment
            let input = Pipe()
            process.standardInput = input
            let log = directory.url.appendingPathComponent(UUID().uuidString + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output
            process.standardError = output
            try process.run()
            return (connection, process, input, output, log)
        }
        func ready(_ connection: TmuxConnection, log: URL) throws -> TmuxSnapshot {
            var value: TmuxSnapshot?
            var lastError: Error?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                do { value = try connection.snapshot() } catch { lastError = error }
                if value != nil { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if let value { return value }
            let marker = try? connection.run(["show-option", "-sqv", try XCTUnwrap(connection.remote).markerOption])
            let clients = try? connection.run(["list-clients", "-F", "#{client_pid} #{client_tty} #{client_control_mode}"])
            return try XCTUnwrap(value, "Last error: \(String(describing: lastError)); marker: \(marker ?? "unavailable"); clients: \(clients ?? "unavailable"); terminal: \((try? String(contentsOf: log, encoding: .utf8))?.suffix(200) ?? "unavailable")")
        }
        let (connection, terminal, input, output, log) = try connect()
        defer {
            connection.retire()
            stop(terminal)
            try? output.close()
            withExtendedLifetime(input) {}
        }
        let initial = try ready(connection, log: log)
        let main = try XCTUnwrap(initial.windows.first)
        let tty = try XCTUnwrap(initial.ownClientTTY)
        XCTAssertEqual(initial.windows.count, 1)
        XCTAssertEqual(main.sessionName, "main")
        XCTAssertEqual(main.path, initial.homeDirectory)
        XCTAssertTrue(tty.hasPrefix("/dev/"))
        XCTAssertNotEqual(initial.clients.first { $0.tty == tty }?.pid, 0)
        XCTAssertTrue(main.isRemote)
        let clientInfo = try connection.run(["list-clients", "-F", "#{client_tty} #{client_termname} #{client_termfeatures}"])
        let ownInfo = try XCTUnwrap(clientInfo.split(separator: "\n").first { $0.hasPrefix(tty + " ") })
        XCTAssertTrue(ownInfo.split(separator: " ").last?.split(separator: ",").contains("RGB") == true, String(ownInfo))
        let remoteTerm = try raw("if infocmp xterm-ghostty >/dev/null 2>&1; then printf xterm-ghostty; else printf xterm-256color; fi")
        XCTAssertEqual(ownInfo.split(separator: " ").dropFirst().first.map(String.init), remoteTerm)
        if env["MUXIFY_SSH_TEST_REQUIRE_AGENT"] == "1" {
            // A custom update-environment may omit the per-Session override;
            // Panes then inherit the server's global environment instead.
            let sessionSocket = try? connection.run(["show-environment", "-t", main.sessionID, "SSH_AUTH_SOCK"])
            let value = try (sessionSocket ?? connection.run(["show-environment", "-g", "SSH_AUTH_SOCK"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(value.hasPrefix("SSH_AUTH_SOCK="))
            let socket = String(value.dropFirst("SSH_AUTH_SOCK=".count))
            _ = try raw("test -S " + Tmux.shellQuote(socket)
                         + " && SSH_AUTH_SOCK=" + Tmux.shellQuote(socket) + " /usr/bin/ssh-add -l >/dev/null")
        }

        let events = TmuxEvents()
        var notificationCount = 0
        events.onEvent = { _ in notificationCount += 1 }
        events.start(sessionID: main.sessionID, connection: connection)
        defer { events.stop() }
        let eventDeadline = Date().addingTimeInterval(5)
        while Date() < eventDeadline {
            if try connection.snapshot().clients.contains(where: \.isControl) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(try connection.snapshot().clients.contains(where: \.isControl))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let beforeMutation = notificationCount

        let name = "literal ' ; $(echo wrong) 😃"
        let windowID = try connection.run(["new-window", "-d", "-P", "-F", "#{window_id}",
                                           "-t", "\(main.sessionID):", "-n", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try connection.run(["switch-client", "-c", tty, "-t", "\(main.sessionID):\(windowID)"])
        let stored = StoredBrowser(tabURLs: ["http://\(host):3000", "https://example.com"], activeTab: 1, isOpen: true)
        _ = try connection.run(stored.setOptionArgs(windowID: windowID))
        let paneID = try connection.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", windowID, "exec /bin/sleep 120"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try connection.run(["set-option", "-pq", "-t", paneID, Tmux.agentOption, "claude",
                                 ";", "set-option", "-pq", "-t", paneID, Tmux.agentStatusOption, "blocked"])
        let updated = try connection.snapshot()
        XCTAssertEqual(updated.windows.first { $0.id == windowID }?.name, name)
        XCTAssertEqual(updated.windows.first { $0.id == windowID }?.storedBrowser, stored)
        XCTAssertEqual(updated.clients.first { $0.tty == tty }?.windowID, windowID)
        XCTAssertEqual(updated.agents.first { $0.paneID == paneID }?.status, .blocked)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(notificationCount, beforeMutation)

        let other = try connection.run(["new-session", "-d", "-s", "other", "-P", "-F", "#{session_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try connection.run(["switch-client", "-c", tty, "-t", other])
        let switched = try connection.snapshot()
        XCTAssertEqual(switched.clients.first { $0.tty == tty }?.sessionID, other)
        XCTAssertEqual(switched.clients.first { $0.isControl }?.sessionID, main.sessionID)
        _ = try connection.run(["rename-window", "-t", windowID, "renamed"])
        let disposable = try connection.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(main.sessionID):"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try connection.run(["kill-window", "-t", disposable])
        XCTAssertEqual(try connection.snapshot().windows.first { $0.id == windowID }?.name, "renamed")
        XCTAssertFalse(try connection.snapshot().windows.contains { $0.id == disposable })

        events.stop()
        _ = try connection.run(["detach-client", "-t", tty])
        stopAfterExit(terminal)
        XCTAssertEqual(connection.remote?.exitStatus, 0)
        XCTAssertFalse(connection.remote?.shouldReconnect ?? true)
        connection.retire()
        XCTAssertThrowsError(try runner.run(try XCTUnwrap(connection.remote).command(["list-sessions"]), timeout: 3)) {
            guard case .failed(let status, _) = $0 as? TmuxError else { return XCTFail("Expected master-only SSH, got \($0)") }
            XCTAssertEqual(status, 255)
        }
        XCTAssertNoThrow(try raw(prefix + "tmux has-session -t '=main'"))

        let (reconnected, nextTerminal, nextInput, nextOutput, nextLog) = try connect()
        defer {
            reconnected.retire()
            stop(nextTerminal)
            try? nextOutput.close()
            withExtendedLifetime(nextInput) {}
        }
        let restored = try ready(reconnected, log: nextLog)
        XCTAssertEqual(restored.windows.first { $0.id == windowID }?.storedBrowser, stored)
        XCTAssertEqual(restored.agents.first { $0.paneID == paneID }?.status, .blocked)
        XCTAssertNotEqual(restored.windows.first?.sourceID, initial.windows.first?.sourceID)

        // Drop only this test's TCP pipe: no VM restart, firewall changes or
        // interference with other SSH connections. tmux must remain running.
        let proxyPID = try XCTUnwrap(Int32(try String(contentsOf: proxyPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(proxyPID, SIGTERM), 0)
        stopAfterExit(nextTerminal)
        XCTAssertEqual(reconnected.remote?.exitStatus, 255)
        XCTAssertTrue(reconnected.remote?.shouldReconnect == true, reconnected.remote?.failureMessage ?? "No SSH diagnostic")
        reconnected.retire()
        XCTAssertNoThrow(try raw(prefix + "tmux has-session -t '=main'"))

        let (recovered, recoveredTerminal, recoveredInput, recoveredOutput, recoveredLog) = try connect()
        defer {
            recovered.retire()
            stop(recoveredTerminal)
            try? recoveredOutput.close()
            withExtendedLifetime(recoveredInput) {}
        }
        let recoveredSnapshot = try ready(recovered, log: recoveredLog)
        XCTAssertEqual(recoveredSnapshot.windows.first { $0.id == windowID }?.storedBrowser, stored)
        XCTAssertEqual(recoveredSnapshot.agents.first { $0.paneID == paneID }?.status, .blocked)
        // Another App Window owns a different master/client on this same host.
        // Retiring the first must not remove the sibling's marker or transport.
        let (sibling, siblingTerminal, siblingInput, siblingOutput, siblingLog) = try connect()
        defer {
            sibling.retire()
            stop(siblingTerminal)
            try? siblingOutput.close()
            withExtendedLifetime(siblingInput) {}
        }
        let siblingSnapshot = try ready(sibling, log: siblingLog)
        XCTAssertNotEqual(siblingSnapshot.ownClientTTY, recoveredSnapshot.ownClientTTY)
        // The quit path must finish background retirement/file cleanup while
        // leaving tmux and its Browser state available for another attachment.
        let cleanup = ConnectionCleanup()
        let shutDown = expectation(description: "background SSH shutdown")
        cleanup.run(retire: { recovered.retire(flushing: [stored.setOptionArgs(windowID: windowID)]) },
                    closeSurface: { self.stop(recoveredTerminal) },
                    cleanup: { recovered.cleanup() })
        cleanup.whenFinished { shutDown.fulfill() }
        wait(for: [shutDown], timeout: 8)
        XCTAssertFalse(recoveredTerminal.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recovered.remote).directory.path))
        XCTAssertTrue(siblingTerminal.isRunning)
        XCTAssertEqual(try sibling.snapshot().ownClientTTY, siblingSnapshot.ownClientTTY)
        XCTAssertNoThrow(try sibling.run(["has-session", "-t", "=main"]))
        XCTAssertNoThrow(try raw(prefix + "tmux has-session -t '=main'"))
        XCTAssertEqual(try raw(prefix + "tmux show-option -wqv -t " + Tmux.shellQuote(windowID) + " " + Tmux.tabsOption)
            .trimmingCharacters(in: .whitespacesAndNewlines), stored.tabURLs.joined(separator: " "))
        print("Live SSH passed on \(username)@\(host): attach, snapshots, client targeting, events, Browser/Agent state, mutations, detach, connection loss, reconnect and independent background shutdown")
    }

    private func stopAfterExit(_ process: Process) {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(process.isRunning, "SSH attachment did not exit")
        if !process.isRunning { process.waitUntilExit() }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
