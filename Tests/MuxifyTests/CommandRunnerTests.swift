import XCTest
import Darwin

final class CommandRunnerTests: XCTestCase {
    func testDefaultEnvironmentInheritsProcessChanges() throws {
        let key = "MUXIFY_TEST_INHERITED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // AppEnvironment prepares children with setenv before launching them.
        let value = "inherited after startup 😃"
        XCTAssertEqual(setenv(key, value, 1), 0)
        defer { unsetenv(key) }
        let output = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/printenv", arguments: [key]))
        XCTAssertEqual(output, value + "\n")
    }

    func testExplicitEnvironmentReplacesInheritedEnvironment() throws {
        let key = "MUXIFY_TEST_REPLACED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(setenv(key, "inherited", 1), 0)
        defer { unsetenv(key) }
        let output = try CommandRunner().run(
            CommandInvocation(executable: "/usr/bin/env", arguments: []),
            environment: ["MUXIFY_TEST_EXPLICIT": "provided"]
        )
        XCTAssertEqual(output, "MUXIFY_TEST_EXPLICIT=provided\n")
    }

    func testBothPipesDrainWithoutDeadlock() throws {
        let script = "i=0; while [ \"$i\" -lt 5000 ]; do printf '%080d\\n' \"$i\" >&2; i=$((i+1)); done; printf ok"
        XCTAssertEqual(try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script])), "ok")
    }

    func testDeadlineKillsAProcessIgnoringTermination() {
        let started = Date()
        XCTAssertThrowsError(try CommandRunner().run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"]), timeout: 0.1
        )) { XCTAssertEqual($0 as? TmuxError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellationStopsAnInFlightProcessAndPreventsFutureLaunches() {
        let runner = CommandRunner()
        let finished = expectation(description: "cancelled subprocess")
        DispatchQueue.global().async {
            do {
                _ = try runner.run(CommandInvocation(executable: "/bin/sleep", arguments: ["10"]))
                XCTFail("A cancelled command must not succeed")
            } catch { XCTAssertEqual(error as? TmuxError, .cancelled) }
            finished.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { runner.cancel() }
        wait(for: [finished], timeout: 3)
        XCTAssertThrowsError(try runner.run(CommandInvocation(executable: "/usr/bin/true", arguments: []))) {
            XCTAssertEqual($0 as? TmuxError, .cancelled)
        }
    }

    func testShellQuotingPreservesSpecialCharactersLiterally() throws {
        for value in ["", "spaces 😃", "single'quote", "semi; echo wrong", "$(echo wrong)", "line\nline", "\\\\path\\'quote", "`echo wrong`", "quote'\u{0301}$(echo wrong)"] {
            XCTAssertEqual(try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", "printf %s " + Tmux.shellQuote(value)])), value)
        }
    }

    func testNestedRemoteShellQuotingWorksWithFish() throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { throw XCTSkip("fish is needed to test remote login-shell quoting") }
        for value in ["", "quotes ' ; $(echo wrong) 😃", "\\\\path\\'quote", "line\nline", "`echo wrong`", "quote'\u{0301}$(echo wrong)"] {
            let command = "exec /bin/sh -c " + Tmux.shellQuote("printf %s " + Tmux.shellQuote(value))
            XCTAssertEqual(try CommandRunner().run(CommandInvocation(executable: fish, arguments: ["--no-config", "-c", command])), value)
        }
    }

    func testRetiredConnectionCannotLaunchEvenADestructiveCommand() throws {
        let connection = try TmuxConnection(environment: nil)
        connection.retire()
        XCTAssertThrowsError(try connection.run(["kill-server"])) { XCTAssertEqual($0 as? TmuxError, .cancelled) }
    }

    func testSnapshotReadsRemoteClientIdentityAndServerLifetime() {
        let s = Tmux.separator
        let snapshot = Tmux.parseSnapshot([
            ["C", "/dev/pts/5", "$0", "@0", "1234", "0"].joined(separator: s),
            ["C", "", "$0", "@0", "1235", "1"].joined(separator: s),
            ["S", "500"].joined(separator: s),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.clients[0].pid, 1234)
        XCTAssertEqual(snapshot.clients[0].tty, "/dev/pts/5")
        XCTAssertFalse(snapshot.clients[0].isControl)
        XCTAssertTrue(snapshot.clients[1].isControl)
        XCTAssertEqual(snapshot.serverID, "500")
    }

    func testRemotePathsDoNotUseTheLocalHome() {
        XCTAssertEqual(Paths.tildify("/home/dev/project", home: "/home/dev"), "~/project")
        XCTAssertEqual(Paths.tildify("/Users/local/project", home: "/home/dev"), "/Users/local/project")
        XCTAssertEqual(Paths.fishStyle("/home/dev/work/project", home: "/home/dev"), "~/w/project")
        let pane = TmuxPane(id: "%0", windowID: "@0", command: "dash", agent: "claude", agentStatus: "done", unread: false)
        XCTAssertFalse(Agent.runs(in: pane))
    }
}
