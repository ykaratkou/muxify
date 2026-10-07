import Foundation

enum CLICommand: Equatable {
    case help
    case browserOpen(window: String, urls: [String])
    case sessionOpen(name: String)
    case extensionsInstall
    case simulator(arguments: [String])

    static let usage = """
    usage: muxify browser open [--window <id>] <url>...
           muxify session open <session name>
           muxify extensions install
           muxify simulator serve [--port <port>] [--origin <https://host>]

    browser open   Opens each URL as a Tab in this tmux Window's Browser.
                     --window <id>   open in another Window instead, e.g. --window @12
    session open   Shows the tmux Session in Muxify. The name may contain spaces,
                   quoted or not: muxify session open my project
    extensions install
                   Installs or updates Extensions for Agents configured under HOME.
    simulator serve  Serves Devices in any browser, independently of the desktop app.
    """

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var args = ArraySlice(arguments)
        switch args.popFirst() {
        case "-h", "--help", "help": self = .help
        case "simulator": self = .simulator(arguments: Array(args))
        case "extensions":
            switch args.popFirst() {
            case "-h", "--help": self = .help
            case "install":
                if args.first == "-h" || args.first == "--help" { self = .help; return }
                guard args.isEmpty else { throw CLIError("extensions install takes no arguments") }
                self = .extensionsInstall
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        case "browser":
            switch args.popFirst() {
            case "-h", "--help": self = .help
            case "open": self = try Self.browser(arguments: args, environment: environment)
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        case "session":
            switch args.popFirst() {
            case "-h", "--help": self = .help
            case "open":
                if args.first == "-h" || args.first == "--help" { self = .help; return }
                if args.first == "--" { args = args.dropFirst() }
                guard !args.isEmpty else { throw CLIError(Self.usage, exitCode: 2) }
                self = .sessionOpen(name: args.joined(separator: " "))
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        default: throw CLIError(Self.usage, exitCode: 2)
        }
    }

    private static func browser(arguments: ArraySlice<String>, environment: [String: String]) throws -> Self {
        var args = arguments
        var target = ""
        options: while let argument = args.first {
            switch argument {
            case "-w", "--window":
                args = args.dropFirst()
                guard let value = args.popFirst() else { throw CLIError(usage, exitCode: 2) }
                target = value
            case let value where value.hasPrefix("--window="):
                target = String(value.dropFirst("--window=".count))
                args = args.dropFirst()
            case "-h", "--help": return .help
            case "--": args = args.dropFirst(); break options
            case let value where value.hasPrefix("-"): throw CLIError("unknown option \(value)")
            default: break options
            }
        }
        guard !args.isEmpty else { throw CLIError(usage, exitCode: 2) }
        if target.isEmpty {
            guard let pane = environment["TMUX_PANE"], !pane.isEmpty else {
                throw CLIError("not inside tmux; specify the Window with --window <id> (e.g. --window @12)")
            }
            target = pane
        }
        for url in args where url.contains(where: { $0.isWhitespace }) {
            throw CLIError("'\(url)' contains spaces; pass one URL per argument")
        }
        return .browserOpen(window: target, urls: Array(args))
    }

    func execute(using runner: any CLICommandRunning = CLIProcessRunner(),
                 executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) async throws {
        switch self {
        case .help: print(Self.usage)
        case .simulator(let arguments): try await SimulatorCommand.serve(arguments: arguments)
        case .extensionsInstall:
            // Installed links point into the app bundle. Resolve them before
            // locating the installer beside its bundled bin directory.
            let installer = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("../extensions/install.sh").standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: installer.path) else {
                throw CLIError("Extension installer is missing beside the command line tool")
            }
            let result = try runner.run("/bin/sh", arguments: [installer.path], quiet: false)
            print(result.output, terminator: "")
            try check(result, command: "Extension installer")
        case .browserOpen(let target, let urls):
            // list-panes validates the target; display-message succeeds even for missing Windows.
            let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
            let window = result.output.components(separatedBy: "\n").first ?? ""
            guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window '\(target)'") }
            // Append so requests made before Muxify's next poll aren't overwritten.
            try check(runner.run("tmux", arguments: ["set-option", "-wa", "-t", window, "@muxify_open", " " + urls.joined(separator: " ")], quiet: false), command: "tmux")
        case .sessionOpen(let name):
            let result = try runner.run("tmux", arguments: ["has-session", "-t", "=\(name)"], quiet: true)
            guard result.status == 0 else { throw CLIError("no tmux session '\(name)'") }
            // Encode every UTF-8 byte, matching the original CLI's session links.
            let encoded = name.utf8.map { String(format: "%%%02x", $0) }.joined()
            try check(runner.run("open", arguments: ["muxify://select?session=\(encoded)"], quiet: false), command: "open")
        }
    }

    private func check(_ result: CLICommandResult, command: String) throws {
        guard result.status == 0 else { throw CLIError("\(command) exited with status \(result.status)", exitCode: result.status) }
    }
}

struct CLIError: LocalizedError {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var errorDescription: String? { message }
}
