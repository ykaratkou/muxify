import XCTest
@testable import MuxifyCLI

final class CLICommandTests: XCTestCase {
    func testHelpDoesNotNeedTmuxOrSimulatorConfiguration() throws {
        for arguments in [["--help"], ["-h"], ["help"], ["browser", "--help"],
                          ["browser", "open", "--help"], ["session", "-h"], ["session", "open", "--help"],
                          ["extensions", "--help"], ["extensions", "install", "--help"]] {
            XCTAssertEqual(try CLICommand(arguments: arguments, environment: [:]), .help)
        }
    }

    func testIncompleteAndUnknownCommandsReturnUsage() {
        for arguments in [[], ["unknown"], ["browser"], ["browser", "close"], ["browser", "open"],
                          ["browser", "open", "--window"], ["session"], ["session", "close"], ["session", "open"],
                          ["extensions"], ["extensions", "unknown"]] {
            XCTAssertThrowsError(try CLICommand(arguments: arguments, environment: [:])) { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2)
                XCTAssertEqual(error.localizedDescription, CLICommand.usage)
            }
        }
    }

    func testBrowserTargetsCallingPaneAndKeepsURLsSeparate() throws {
        XCTAssertEqual(try CLICommand(arguments: ["browser", "open", "localhost:3000", "https://example.com/#token=secret"],
                                      environment: ["TMUX_PANE": "%7"]),
                       .browserOpen(window: "%7", urls: ["localhost:3000", "https://example.com/#token=secret"]))
    }

    func testBrowserExplicitWindowWorksOutsideTmux() throws {
        for options in [["--window", "@12"], ["-w", "@12"], ["--window=@12"]] {
            XCTAssertEqual(try CLICommand(arguments: ["browser", "open"] + options + ["https://example.com"], environment: [:]),
                           .browserOpen(window: "@12", urls: ["https://example.com"]))
        }
        XCTAssertEqual(try CLICommand(arguments: ["browser", "open", "--window", "@12", "--", "-url"], environment: [:]),
                       .browserOpen(window: "@12", urls: ["-url"]))
    }

    func testBrowserRejectsMissingTargetUnknownOptionsAndWhitespace() {
        XCTAssertThrowsError(try CLICommand(arguments: ["browser", "open", "localhost:3000"], environment: [:]))
        for argument in ["--unknown", "https://example.com/a b", "https://example.com/a\nb"] {
            XCTAssertThrowsError(try CLICommand(arguments: ["browser", "open", argument], environment: ["TMUX_PANE": "%7"]))
        }
    }

    func testSessionNamesMayBeQuotedUnquotedOrStartWithAnOption() throws {
        for arguments in [["my project"], ["my", "project"]] {
            XCTAssertEqual(try CLICommand(arguments: ["session", "open"] + arguments), .sessionOpen(name: "my project"))
        }
        XCTAssertEqual(try CLICommand(arguments: ["session", "open", "--", "--help"]), .sessionOpen(name: "--help"))
    }

    func testSimulatorArgumentsAreHandledByBuiltInServerCommand() throws {
        let arguments = ["serve", "--port", "9000", "--origin", "https://mac.example"]
        XCTAssertEqual(try CLICommand(arguments: ["simulator"] + arguments, environment: [:]), .simulator(arguments: arguments))
    }

    func testExtensionsInstallNeedsNoTmuxAndRejectsArguments() throws {
        XCTAssertEqual(try CLICommand(arguments: ["extensions", "install"], environment: [:]), .extensionsInstall)
        XCTAssertThrowsError(try CLICommand(arguments: ["extensions", "install", "unexpected"], environment: [:])) { error in
            XCTAssertEqual(error.localizedDescription, "extensions install takes no arguments")
        }
    }

    func testExtensionsInstallerIsLocatedThroughRelativeSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-cli-extensions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Muxify.app/Contents/Resources")
        let executable = resources.appendingPathComponent("bin/muxify")
        let installer = resources.appendingPathComponent("extensions/install.sh")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try Data().write(to: installer)
        let link = root.appendingPathComponent("installed-muxify")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Muxify.app/Contents/Resources/bin/muxify")
        let runner = RecordingRunner(results: [.init(status: 0, output: "")])
        try await CLICommand.extensionsInstall.execute(using: runner, executableURL: link)
        XCTAssertEqual(runner.calls, [.init(command: "/bin/sh", arguments: [installer.path], quiet: false)])
    }

    func testMissingExtensionsInstallerDoesNotRunACommand() async {
        let runner = RecordingRunner(results: [])
        do {
            try await CLICommand.extensionsInstall.execute(using: runner, executableURL: URL(fileURLWithPath: "/missing/bin/muxify"))
            XCTFail("Expected missing installer error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Extension installer is missing beside the command line tool")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testBrowserAppendsRequestToResolvedWindow() async throws {
        let runner = RecordingRunner(results: [.init(status: 0, output: "@12\n@12\n"), .init(status: 0, output: "")])
        try await CLICommand.browserOpen(window: "%7", urls: ["localhost:3000", "https://example.com"]).execute(using: runner)
        XCTAssertEqual(runner.calls, [
            .init(command: "tmux", arguments: ["list-panes", "-t", "%7", "-F", "#{window_id}"], quiet: true),
            .init(command: "tmux", arguments: ["set-option", "-wa", "-t", "@12", "@muxify_open", " localhost:3000 https://example.com"], quiet: false),
        ])
    }

    func testMissingBrowserWindowDoesNotWriteOptions() async {
        for result in [CLICommandResult(status: 1, output: ""), .init(status: 0, output: "")] {
            let runner = RecordingRunner(results: [result])
            do {
                try await CLICommand.browserOpen(window: "@404", urls: ["localhost:3000"]).execute(using: runner)
                XCTFail("Expected missing Window error")
            } catch {
                XCTAssertEqual(error.localizedDescription, "no tmux Window '@404'")
            }
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testSessionUsesExactNameAndPercentEncodesUTF8() async throws {
        let runner = RecordingRunner(results: [.init(status: 0, output: ""), .init(status: 0, output: "")])
        try await CLICommand.sessionOpen(name: "a &猫").execute(using: runner)
        XCTAssertEqual(runner.calls, [
            .init(command: "tmux", arguments: ["has-session", "-t", "=a &猫"], quiet: true),
            .init(command: "open", arguments: ["muxify://select?session=%61%20%26%e7%8c%ab"], quiet: false),
        ])
    }

    func testMissingSessionDoesNotOpenApp() async {
        let runner = RecordingRunner(results: [.init(status: 1, output: "")])
        do {
            try await CLICommand.sessionOpen(name: "missing").execute(using: runner)
            XCTFail("Expected missing Session error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "no tmux session 'missing'")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSubcommandFailurePreservesExitCode() async {
        let runner = RecordingRunner(results: [.init(status: 0, output: "@12\n"), .init(status: 7, output: "")])
        do {
            try await CLICommand.browserOpen(window: "%7", urls: ["localhost:3000"]).execute(using: runner)
            XCTFail("Expected tmux failure")
        } catch {
            XCTAssertEqual((error as? CLIError)?.exitCode, 7)
        }
    }

    func testProcessRunnerPreservesArgumentBoundaries() throws {
        let result = try CLIProcessRunner().run("/usr/bin/printf", arguments: ["%s\n", "a b", "x; y", "$HOME"], quiet: false)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "a b\nx; y\n$HOME\n")
    }
}

private final class RecordingRunner: CLICommandRunning {
    struct Call: Equatable {
        let command: String
        let arguments: [String]
        let quiet: Bool
    }

    var calls: [Call] = []
    var results: [CLICommandResult]

    init(results: [CLICommandResult]) { self.results = results }

    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult {
        calls.append(Call(command: command, arguments: arguments, quiet: quiet))
        return results.removeFirst()
    }
}
