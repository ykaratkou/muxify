import Foundation

/// Which coding-agent CLI an Agent is, as its Extension names it in the Pane's
/// `@muxify_agent` option (ADR 0004). The raw value is also its icon's name.
enum AgentKind: String, CaseIterable {
    case claude, codex, opencode, pi

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }
}

/// What an Agent is doing, from the Pane's `@muxify_agent_status` option.
enum AgentStatus: String {
    case working, blocked, done, failed

    /// Reaching this Status while you aren't looking makes the Agent unread.
    var needsAttention: Bool { self != .working }
}

/// An Agent running in a Pane, as listed in the sidebar's Agents section.
struct Agent: Identifiable, Hashable {
    /// The Pane the Agent runs in, e.g. "%42".
    let paneID: String
    let kind: AgentKind
    /// nil until the Agent has run a turn.
    let status: AgentStatus?
    /// It finished or got blocked while you weren't looking at its Window.
    let unread: Bool
    let windowID: String
    let sessionID: String
    let sessionName: String
    let windowIndex: Int
    /// The Window's `displayTitle`.
    let windowTitle: String
    var sourceID = ""

    var id: String { paneID }

    /// `session:window`, e.g. `muxify:2`.
    var location: String { "\(sessionName):\(windowIndex)" }

    /// Whether the Pane runs an Agent. A Pane back at a plain shell doesn't:
    /// an Agent killed without cleaning up leaves its options behind.
    static func runs(in pane: TmuxPane) -> Bool {
        AgentKind(rawValue: pane.agent) != nil && !Tmux.shellNames.contains(pane.command)
    }

    /// One Agent per Pane that runs one: the unread Agents first, then the
    /// working ones, then the rest you have seen, each in tmux order
    /// (Session, Window, Pane).
    static func list(panes: [TmuxPane], windows: [TmuxWindow]) -> [Agent] {
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = panes.compactMap { pane -> Agent? in
            guard runs(in: pane),
                  let kind = AgentKind(rawValue: pane.agent),
                  let window = windowsByID[pane.windowID]
            else { return nil }
            return Agent(
                paneID: pane.id,
                kind: kind,
                status: AgentStatus(rawValue: pane.agentStatus),
                unread: pane.unread,
                windowID: window.id,
                sessionID: window.sessionID,
                sessionName: window.sessionName,
                windowIndex: window.index,
                windowTitle: window.displayTitle,
                sourceID: window.sourceID
            )
        }
        return agents.filter(\.unread)
            + agents.filter { !$0.unread && $0.status == .working }
            + agents.filter { !$0.unread && $0.status != .working }
    }
}
