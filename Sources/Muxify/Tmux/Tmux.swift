import Foundation

/// A tmux window as shown in the sidebar.
struct TmuxWindow: Identifiable, Hashable {
    /// Server-unique window id, e.g. "@27".
    let id: String
    let sessionID: String
    let sessionName: String
    let index: Int
    let name: String
    let paneTitle: String
    let path: String
    let command: String
    let isActive: Bool
    let paneCount: Int
    let hasBell: Bool
    let sessionActivity: Int
    /// The active Pane's `@muxify_agent`, empty when no Agent reports there.
    let agent: String
    /// The Window's Browser as last written to its tmux options.
    var storedBrowser: StoredBrowser
    /// URLs a program asked to open via `@muxify_open` (not yet consumed).
    var openRequests: [String]
    var homeDirectory = NSHomeDirectory()
    var hostName = Tmux.hostName
    var isRemote = false
    /// Connection/server ownership, so a stale UI item cannot address reused IDs.
    var sourceID = ""

    /// The pane title is what shells and TUIs set via OSC 0/2 (fish sets it to
    /// `~/w/project`), so it is the best human label. tmux defaults it to the
    /// hostname, in which case we fall back to the window name or the path.
    var displayTitle: String {
        let title = Self.withoutLeadingGlyph(withoutSSHHostPrefix(paneTitle.trimmingCharacters(in: .whitespaces)))
        if !title.isEmpty, title != hostName, title != hostName.split(separator: ".").first.map(String.init) {
            return title
        }
        if !Tmux.shellNames.contains(name) { return name }
        return Paths.fishStyle(path, home: homeDirectory)
    }

    var abbreviatedPath: String { Paths.tildify(path, home: homeDirectory) }

    /// The logo for what the active Pane runs (`Resources/Logos`): the Agent
    /// it reports, else its command. Claude Code shows up as its version
    /// number (`2.1.289`) until its Extension reports. A command's version
    /// suffix and case don't matter (`python3.12`, `Python` → `python`).
    /// Shells get the terminal logo.
    var logoName: String {
        if AgentKind(rawValue: agent) != nil { return agent }
        if Tmux.shellNames.contains(command) { return "terminal" }
        if command.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { return AgentKind.claude.rawValue }
        if let alias = Self.commandAliases[command] { return alias }
        let name = command.lowercased().replacingOccurrences(of: #"[\d.]+$"#, with: "", options: .regularExpression)
        return Self.commandAliases[name] ?? (name.isEmpty ? command : name)
    }

    /// Commands that share another command's logo.
    private static let commandAliases = [
        "vim": "nvim", "vi": "nvim",
        "cargo": "rust", "rustc": "rust",
        "postgres": "psql",
        "redis-cli": "redis", "redis-server": "redis",
    ]

    /// fish prefixes SSH titles with `[hostname]` (truncated to 10 characters).
    /// The Environment selector already identifies this host. Keep prefixes
    /// for other hosts/tasks and leave the underlying tmux title untouched.
    private func withoutSSHHostPrefix(_ title: String) -> String {
        guard isRemote, !hostName.isEmpty else { return title }
        let shortHost = hostName.split(separator: ".").first.map(String.init) ?? hostName
        for host in Set([hostName, shortHost, String(hostName.prefix(10)), String(shortHost.prefix(10))]) {
            let prefix = "[\(host)]"
            if title == prefix { return "" }
            if title.hasPrefix(prefix + " ") {
                return String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    /// Claude Code titles its terminal "✳ <conversation>" and animates the
    /// glyph while it works; the logo already says it's Claude.
    private static func withoutLeadingGlyph(_ title: String) -> String {
        let scalars = title.unicodeScalars.drop { $0.properties.generalCategory == .otherSymbol || $0 == "·" }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? title : text
    }
}

/// A Window's Browser as stored in tmux window options (ADR 0003). Tab URLs
/// are space-separated (URLs never contain spaces); an empty Tab is
/// `about:blank`.
struct StoredBrowser: Hashable {
    var tabURLs: [String] = []
    var activeTab = 0
    var isOpen = false

    init(tabURLs: [String] = [], activeTab: Int = 0, isOpen: Bool = false) {
        self.tabURLs = tabURLs
        self.activeTab = activeTab
        self.isOpen = isOpen
    }

    init(tabs: String, activeTab: String, open: String) {
        tabURLs = tabs.split(separator: " ").map(String.init)
        self.activeTab = Int(activeTab) ?? 0
        isOpen = open == "on"
    }

    /// `set-option` arguments that write this state onto `windowID`.
    func setOptionArgs(windowID: String) -> [String] {
        guard !tabURLs.isEmpty else {
            return Array([Tmux.tabsOption, Tmux.activeTabOption, Tmux.browserOpenOption].flatMap {
                ["set-option", "-wqu", "-t", windowID, $0, ";"]
            }.dropLast())
        }
        return ["set-option", "-wq", "-t", windowID, Tmux.tabsOption, tabURLs.joined(separator: " "),
                ";", "set-option", "-wq", "-t", windowID, Tmux.activeTabOption, String(activeTab),
                ";", "set-option", "-wq", "-t", windowID, Tmux.browserOpenOption, isOpen ? "on" : "off"]
    }
}

/// A client attached to the tmux server (one of them is ours).
struct TmuxClient: Hashable {
    let tty: String
    let sessionID: String
    let windowID: String
    var pid = 0
    var isControl = false
}

/// A tmux Pane, with the options an Agent's Extension writes onto it (ADR 0004).
struct TmuxPane: Hashable {
    /// Server-unique pane id, e.g. "%42".
    let id: String
    let windowID: String
    /// `#{pane_current_command}`. It can't identify an Agent (Claude Code's is
    /// its version number), but a plain shell here means no Agent is running.
    let command: String
    /// `@muxify_agent`, empty when unset.
    let agent: String
    /// `@muxify_agent_status`, empty when unset.
    let agentStatus: String
    /// `@muxify_agent_unread`, which Muxify itself sets.
    let unread: Bool
}

struct TmuxSnapshot {
    var windows: [TmuxWindow]
    var clients: [TmuxClient]
    var panes: [TmuxPane]
    /// The Window last selected in Muxify (a server-wide option, so it can't
    /// outlive the server and point at a reused window id).
    var lastWindowID: String?
    var serverRunning: Bool
    var serverID: String?
    var ownClientTTY: String?
    var homeDirectory: String?

    /// The Agents running in this snapshot's Panes, in tmux order.
    var agents: [Agent] { Agent.list(panes: panes, windows: windows) }
}

enum TmuxError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case failed(status: Int32, stderr: String)
    case cancelled
    case timedOut
    case notReady

    var description: String {
        switch self {
        case .notInstalled: return "tmux was not found on this Mac"
        case .failed(let status, let stderr): return "tmux exited with \(status): \(stderr)"
        case .cancelled: return "The Environment connection was closed"
        case .timedOut: return "The tmux command timed out"
        case .notReady: return "Waiting for the SSH connection and remote tmux client"
        }
    }
}

enum Tmux {
    static let binary: String? = locateBinary()
    static let hostName = ProcessInfo.processInfo.hostName
    static let shortHostName = hostName.split(separator: ".").first.map(String.init) ?? hostName
    static let shellNames: Set<String> = ["fish", "zsh", "bash", "sh", "dash", "ash", "ksh", "csh", "tcsh", "nu", "elvish", "xonsh", "login"]

    // tmux user options Muxify keeps its state in.
    static let tabsOption = "@muxify_tabs"
    static let activeTabOption = "@muxify_active_tab"
    static let browserOpenOption = "@muxify_browser"
    /// One-shot: programs set it to open a Tab; Muxify consumes and clears it.
    static let openOption = "@muxify_open"
    static let lastWindowOption = "@muxify_last_window"
    // Pane options an Agent's Extension writes (ADR 0004).
    static let agentOption = "@muxify_agent"
    static let agentStatusOption = "@muxify_agent_status"
    /// Set by Muxify, not the Extension: the Agent finished or got blocked
    /// while you weren't looking at its Window.
    static let agentUnreadOption = "@muxify_agent_unread"

    static let separator = "\u{241F}"

    private static func locateBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/run/current-system/sw/bin/tmux",
            "\(NSHomeDirectory())/.nix-profile/bin/tmux",
            "/usr/bin/tmux",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tmux" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        guard let binary else { throw TmuxError.notInstalled }
        return try Shell.run(binary, args)
    }

    /// One round trip that lists every window on the server, every client and
    /// every pane (for the Agents in them).
    static func readSnapshot(using execute: ([String]) throws -> String) throws -> TmuxSnapshot {
        let s = separator
        let windowFormat = [
            "W", "#{window_id}", "#{session_id}", "#{session_name}", "#{window_index}",
            "#{window_name}", "#{pane_title}", "#{pane_current_path}", "#{pane_current_command}",
            "#{window_active}", "#{window_panes}", "#{window_bell_flag}", "#{session_activity}",
            "#{\(tabsOption)}", "#{\(activeTabOption)}", "#{\(browserOpenOption)}", "#{\(openOption)}",
            "#{\(lastWindowOption)}", "#{\(agentOption)}",
        ].joined(separator: s)
        let clientFormat = ["C", "#{client_tty}", "#{session_id}", "#{window_id}", "#{client_pid}", "#{client_control_mode}"].joined(separator: s)
        let paneFormat = [
            "P", "#{pane_id}", "#{window_id}", "#{pane_current_command}",
            "#{\(agentOption)}", "#{\(agentStatusOption)}", "#{\(agentUnreadOption)}",
        ].joined(separator: s)

        let output = try execute([
                "list-windows", "-a", "-F", windowFormat,
                ";", "list-clients", "-F", clientFormat,
                ";", "list-panes", "-a", "-F", paneFormat,
                ";", "display-message", "-p", "-F", "S\(s)#{pid}",
            ])
        return parseSnapshot(output)
    }

    static func parseSnapshot(_ output: String) -> TmuxSnapshot {
        let s = separator
        var windows: [TmuxWindow] = []
        var clients: [TmuxClient] = []
        var panes: [TmuxPane] = []
        var lastWindowID: String?
        var serverID: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.components(separatedBy: s)
            if f.first == "W", f.count >= 19 {
                windows.append(TmuxWindow(
                    id: f[1], sessionID: f[2], sessionName: f[3], index: Int(f[4]) ?? 0,
                    name: f[5], paneTitle: f[6], path: f[7], command: f[8],
                    isActive: f[9] == "1", paneCount: Int(f[10]) ?? 1,
                    hasBell: f[11] == "1",
                    sessionActivity: Int(f[12]) ?? 0,
                    agent: f[18],
                    storedBrowser: StoredBrowser(tabs: f[13], activeTab: f[14], open: f[15]),
                    openRequests: f[16].split(separator: " ").map(String.init)
                ))
                if !f[17].isEmpty { lastWindowID = f[17] }
            } else if f.first == "C", f.count >= 4 {
                clients.append(TmuxClient(tty: f[1], sessionID: f[2], windowID: f[3],
                                          pid: f.count > 4 ? Int(f[4]) ?? 0 : 0,
                                          isControl: f.count > 5 && f[5] == "1"))
            } else if f.first == "P", f.count >= 7 {
                panes.append(TmuxPane(
                    id: f[1], windowID: f[2], command: f[3],
                    agent: f[4], agentStatus: f[5], unread: f[6] == "1"
                ))
            } else if f.first == "S", f.count >= 2 {
                serverID = f[1]
            }
        }
        return TmuxSnapshot(
            windows: windows, clients: clients, panes: panes,
            lastWindowID: lastWindowID, serverRunning: true, serverID: serverID
        )
    }

    static func shellQuote(_ value: String) -> String {
        // Remote SSH commands first pass through the account's login shell.
        // Quote apostrophes/backslashes in separate double-quoted fragments:
        // unlike POSIX's '\\'' idiom, this also preserves bytes through fish.
        "'" + value.unicodeScalars.map { scalar in
            switch scalar {
            case "'": return "'\"'\"'"
            case "\\": return "'\"\\\\\"'"
            default: return String(scalar)
            }
        }.joined() + "'"
    }
}

enum Shell {
    /// Runs a program synchronously and returns stdout. Throws on non-zero exit.
    static func run(_ executable: String, _ args: [String]) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: executable, arguments: args))
    }
}

enum Paths {
    static let home = NSHomeDirectory()

    /// `/Users/me/work/app` -> `~/work/app`
    static func tildify(_ path: String, home: String = Paths.home) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// fish's `prompt_pwd`: `/Users/me/work/app` -> `~/w/app`
    static func fishStyle(_ path: String, home: String = Paths.home) -> String {
        let parts = tildify(path, home: home).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return tildify(path, home: home) }
        let shortened = parts.enumerated().map { index, part -> String in
            if index == parts.count - 1 || part.isEmpty || part == "~" { return String(part) }
            let prefixLength = part.hasPrefix(".") ? 2 : 1
            return String(part.prefix(prefixLength))
        }
        return shortened.joined(separator: "/")
    }
}
