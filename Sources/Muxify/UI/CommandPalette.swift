import AppKit
import SwiftUI

// MARK: - Items

/// A Command Palette result: a running Session, a Session Path, a Window or
/// an Agent.
struct PaletteItem: Identifiable {
    enum Kind {
        case session, sessionPath, window, agent

        var source: PaletteSource {
            switch self {
            case .session, .sessionPath: .sessions
            case .window: .windows
            case .agent: .agents
            }
        }
    }

    enum Ref {
        case session(SessionGroup)
        case sessionPath(SessionPath)
        case window(TmuxWindow)
        case agent(Agent)
    }

    let id: String
    let kind: Kind
    let ref: Ref
    let title: String
    /// What it is ("Session", "Worktree", "Claude Code"), and where.
    let subtitle: String
    let path: String
    /// What Copy tmux Target copies: a Session name, `session:index`, or a
    /// Pane ID. A Session Path has none.
    let target: String?
    /// A `Resources/Logos` name, for Windows and Agents.
    var logo: String?
    var status: AgentStatus?
    var unread = false
    var isCurrent = false
    /// Matched after the title, with less weight.
    var keywords = ""
    /// The Session's last activity, which breaks ties.
    var activity = 0
}

/// What the Command Palettes of an App Window search.
struct PaletteCatalog {
    var windows: [TmuxWindow]
    var agents: [Agent]
    var sessionPaths: [SessionPath]
    var selectedWindowID: String?
    var homeDirectory = NSHomeDirectory()

    /// One Source's results for an empty query, in its order:
    /// - Sessions, most recently active first and the current one last, then
    ///   the Session Paths that have no Session.
    /// - Agents that need you (blocked, failed or unread), then working ones,
    ///   then the rest.
    /// - Windows in Sidebar order. A Window with an Agent can be left out:
    ///   the Agent's row stands for it.
    func items(_ source: PaletteSource, hidingAgentWindows: Bool = false) -> [PaletteItem] {
        switch source {
        case .sessions: return sessionItems + sessionPathItems
        case .windows: return windowItems(hidingAgentWindows: hidingAgentWindows)
        case .agents: return agentItems
        }
    }

    private var groups: [SessionGroup] {
        var groups: [SessionGroup] = []
        for window in windows {
            if let last = groups.indices.last, groups[last].id == window.sessionID {
                groups[last].windows.append(window)
            } else {
                groups.append(SessionGroup(id: window.sessionID, name: window.sessionName, windows: [window]))
            }
        }
        return groups
    }

    private var sessionItems: [PaletteItem] {
        let items = groups.map { session -> PaletteItem in
            let active = session.windows.first(where: \.isActive) ?? session.windows[0]
            let folder = session.windows[0].sessionPath.isEmpty ? active.path : session.windows[0].sessionPath
            let count = session.windows.count
            return PaletteItem(
                id: "session:\(session.id)", kind: .session, ref: .session(session),
                title: session.name,
                subtitle: "Session · \(count) window\(count == 1 ? "" : "s") · \(Paths.tildify(folder, home: homeDirectory))",
                path: folder, target: session.name,
                isCurrent: session.windows.contains { $0.id == selectedWindowID },
                keywords: Paths.tildify(folder, home: homeDirectory),
                activity: active.sessionActivity
            )
        }
        let byRecency = items.sorted { $0.activity > $1.activity }
        return byRecency.filter { !$0.isCurrent } + byRecency.filter(\.isCurrent)
    }

    private var sessionPathItems: [PaletteItem] {
        let folders = groups.map { $0.windows[0].sessionPath }
        return sessionPaths
            .filter { path in !folders.contains { SessionPaths.matches(path, sessionFolder: $0) } }
            .map { path in
                let shown = Paths.tildify(path.path, home: homeDirectory)
                return PaletteItem(
                    id: "path:\(path.path)", kind: .sessionPath, ref: .sessionPath(path),
                    title: path.sessionName,
                    subtitle: "\(path.isWorktree ? "Worktree" : "Folder") · \(shown)",
                    path: path.path, target: nil, keywords: shown
                )
            }
    }

    private func windowItems(hidingAgentWindows: Bool) -> [PaletteItem] {
        let agentWindows = hidingAgentWindows ? Set(agents.map(\.windowID)) : []
        return windows.filter { !agentWindows.contains($0.id) }.map { window in
            let target = "\(window.sessionName):\(window.index)"
            return PaletteItem(
                id: "window:\(window.id)", kind: .window, ref: .window(window),
                title: window.displayTitle,
                subtitle: "Window · \(target) · \(window.abbreviatedPath)",
                path: window.path, target: target, logo: window.logoName,
                isCurrent: window.id == selectedWindowID,
                keywords: "\(target) \(window.command) \(window.abbreviatedPath)",
                activity: window.sessionActivity
            )
        }
    }

    private var agentItems: [PaletteItem] {
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ agent: Agent) -> Int {
            if agent.unread || agent.status == .blocked || agent.status == .failed { return 0 }
            return agent.status == .working ? 1 : 2
        }
        // A stable sort keeps tmux order within each rank.
        let ordered = agents.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ordered.map { agent in
            let window = windowsByID[agent.windowID]
            let path = agent.path.isEmpty ? window?.path ?? "" : agent.path
            return PaletteItem(
                id: "agent:\(agent.paneID)", kind: .agent, ref: .agent(agent),
                title: agent.windowTitle,
                subtitle: "\(agent.kind.displayName) · \(agent.location)",
                path: path, target: agent.paneID, logo: agent.kind.rawValue,
                status: agent.status, unread: agent.unread,
                isCurrent: agent.windowID == selectedWindowID,
                keywords: "\(agent.kind.displayName) \(agent.location) \(agent.status?.rawValue ?? "") \(Paths.tildify(path, home: homeDirectory))",
                activity: window?.sessionActivity ?? 0
            )
        }
    }
}

enum PaletteSearch {
    /// Searches the `sources` whose chips are on. With nothing typed, each
    /// one's list in chip order; Windows only when theirs is the only chip
    /// on. Otherwise one list, best match first; on a tie running Sessions
    /// come before Session Paths, then more recent activity first.
    static func results(sources: [PaletteSource], query: String, catalog: PaletteCatalog) -> [PaletteItem] {
        let hidingAgentWindows = sources.contains(.agents)
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return sources.filter { $0 != .windows || sources == [.windows] }
                .flatMap { catalog.items($0, hidingAgentWindows: hidingAgentWindows) }
        }
        let items = sources.flatMap { catalog.items($0, hidingAgentWindows: hidingAgentWindows) }
        var scored: [(offset: Int, score: Int, item: PaletteItem)] = []
        for (offset, item) in items.enumerated() {
            if let score = score(item, words: words) { scored.append((offset, score, item)) }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let rankA = a.item.kind == .sessionPath ? 1 : 0
            let rankB = b.item.kind == .sessionPath ? 1 : 0
            if rankA != rankB { return rankA < rankB }
            if a.item.activity != b.item.activity { return a.item.activity > b.item.activity }
            return a.offset < b.offset
        }.map(\.item)
    }

    /// Every word must match the title or, for less, the subtitle and keywords.
    static func score(_ item: PaletteItem, words: [String]) -> Int? {
        var score = 0
        for word in words {
            if let match = fuzzy(word, in: item.title) {
                score += match * 2
            } else if let match = fuzzy(word, in: item.subtitle + " " + item.keywords) {
                score += match
            } else {
                return nil
            }
        }
        return score
    }

    /// Scores contiguous matches first; otherwise the word's letters in order,
    /// rewarding runs and word starts.
    static func fuzzy(_ word: String, in text: String) -> Int? {
        let haystack = Array(text.lowercased())
        let needle = Array(word)
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        if let start = (0...(haystack.count - needle.count)).first(where: { Array(haystack[$0..<$0 + needle.count]) == needle }) {
            let atWordStart = start == 0 || !(haystack[start - 1].isLetter || haystack[start - 1].isNumber)
            return 100 + needle.count * 10 + (atWordStart ? 40 : 0) - start
        }
        var first: Int?
        var last: Int?
        var score = 0
        var next = 0
        for (offset, character) in haystack.enumerated() where next < needle.count && character == needle[next] {
            var gain = 2
            if let last, last == offset - 1 { gain += 6 }
            if offset == 0 || !(haystack[offset - 1].isLetter || haystack[offset - 1].isNumber) { gain += 8 }
            score += gain
            first = first ?? offset
            last = offset
            next += 1
        }
        guard next == needle.count else { return nil }
        return score - (first ?? 0) / 3
    }
}

// MARK: - State

/// The Command Palette of one App Window (ADR 0009): which palette is open,
/// what is typed, and what is selected.
@MainActor @Observable
final class CommandPalette {
    private(set) var current: CommandPaletteConfig?
    var query = "" {
        didSet { if query != oldValue { selectedID = nil } }
    }
    /// nil selects the first result.
    var selectedID: String?
    /// The chips that are on: the palette's `sources` when it opens.
    var selection: Set<PaletteSource> = [] {
        didSet { if selection != oldValue { selectedID = nil } }
    }
    var showsActions = false
    var actionIndex = 0
    /// What the last Copy put on the pasteboard, shown briefly at the App Window's bottom.
    private(set) var copied: PaletteCopy?

    @ObservationIgnored weak var store: WorkspaceStore?
    @ObservationIgnored private var copiedWork: DispatchWorkItem?
    @ObservationIgnored private var previousResponder: NSResponder?
    #if DEBUG
    @ObservationIgnored private var demoObserver: NSObjectProtocol?
    #endif

    init() {
        #if DEBUG
        observeDemoRequests()
        #endif
    }

    var isOpen: Bool { current != nil }

    var theme: PaletteTheme { PaletteTheme(store?.theme) }

    /// One chip per Source; ⌘1… switch them on and off.
    var chips: [PaletteSource] { current?.chips ?? [] }

    /// The last chip that is on stays on.
    func toggleChip(_ source: PaletteSource) {
        if !selection.contains(source) {
            selection.insert(source)
        } else if selection.count > 1 {
            selection.remove(source)
        }
    }

    // MARK: Results

    var results: [PaletteItem] {
        guard let current, let store else { return [] }
        let catalog = PaletteCatalog(windows: store.windows, agents: store.agents, sessionPaths: store.sessionPaths,
                                     selectedWindowID: store.selectedWindowID, homeDirectory: store.homeDirectory)
        return PaletteSearch.results(sources: chips.filter(selection.contains), query: query, catalog: catalog)
    }

    func selected(in items: [PaletteItem]) -> PaletteItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    /// The actions menu's entries; Jump To is the first.
    func actions(for item: PaletteItem) -> [PaletteAction] {
        item.target == nil ? [.jumpTo, .copyPath] : [.jumpTo, .copyPath, .copyTarget]
    }

    func title(of action: PaletteAction, for item: PaletteItem) -> String {
        switch action {
        case .jumpTo:
            switch item.kind {
            case .session: "Switch to Session"
            case .sessionPath: "Open as Session"
            case .window: "Open Window"
            case .agent: "Jump to Agent"
            }
        case .copyPath: "Copy Path"
        case .copyTarget: item.kind == .agent ? "Copy Pane ID" : "Copy tmux Target"
        case .selectNext, .selectPrev, .showActions: action.rawValue
        }
    }

    /// As menus write it, e.g. `⌘C`.
    func shortcut(for action: PaletteAction) -> String? {
        store?.config.paletteKeybinds.firstTrigger(for: action)?.symbol
    }

    // MARK: Opening and closing

    /// Its own keybinding closes a palette; another palette's switches to
    /// that one and keeps what is typed.
    func toggle(_ palette: CommandPaletteConfig) {
        if current?.name == palette.name {
            close()
            return
        }
        if current == nil {
            previousResponder = store?.terminalHost.window?.firstResponder
            query = ""
            selectedID = nil
        }
        current = palette
        selection = Set(palette.sources)
        showsActions = false
        actionIndex = 0
        store?.paletteDidOpen(palette)
    }

    func close(restoringFocus: Bool = true) {
        guard current != nil else { return }
        current = nil
        showsActions = false
        let responder = previousResponder
        previousResponder = nil
        guard restoringFocus, let store else { return }
        DispatchQueue.main.async { [weak store] in
            guard let store else { return }
            if let responder, let window = store.terminalHost.window, window.makeFirstResponder(responder) { return }
            store.focusTerminal()
        }
    }

    // MARK: Running actions

    func perform(_ action: PaletteAction, on item: PaletteItem) {
        guard let store else { return }
        switch action {
        case .jumpTo:
            close(restoringFocus: false)
            switch item.ref {
            case .agent(let agent): store.select(agent)
            case .window(let window): store.select(window)
            case .session(let session):
                if let window = session.windows.first(where: \.isActive) ?? session.windows.first { store.select(window) }
            case .sessionPath(let path): store.open(path)
            }
        case .copyPath:
            copy(item.path, title: "Copied Path", shown: Paths.tildify(item.path, home: store.homeDirectory))
        case .copyTarget:
            guard let target = item.target else { return }
            copy(target, title: item.kind == .agent ? "Copied Pane ID" : "Copied tmux Target", shown: target)
        case .selectNext, .selectPrev, .showActions:
            break
        }
    }

    /// The palette fades out while the pill springs in at the App Window's bottom.
    private func copy(_ value: String, title: String, shown: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { close() }
        showCopied(title: title, value: shown)
    }

    /// Shared by palette and Browser copies, without taking keyboard focus.
    func showCopied(title: String, value: String) {
        copiedWork?.cancel()
        let confirmation = PaletteCopy(title: title, value: value)
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { copied = confirmation }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.copied?.id == confirmation.id else { return }
                withAnimation(.easeIn(duration: 0.2)) { self.copied = nil }
            }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Keys

    /// Sees each key in the App Window before the other keybinds while a
    /// palette is open and its search field has focus. ⎋ and ⌘1–⌘3 are fixed;
    /// the rest come from `keybindings.command_palette`.
    func handle(_ trigger: KeyTrigger, in event: NSEvent) -> Bool {
        guard current != nil, let store else { return false }
        // Clicked away (into the terminal or a page): typing goes there.
        guard (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true else {
            close(restoringFocus: false)
            return false
        }
        // As in Spotlight, ⎋ clears before it closes.
        if trigger == Self.escape {
            if showsActions {
                showsActions = false
            } else if !query.isEmpty || selection != Set(current?.sources ?? []) {
                query = ""
                selection = Set(current?.sources ?? [])
            } else {
                close()
            }
            return true
        }
        let items = results
        let item = selected(in: items)
        if let action = store.config.paletteKeybinds.action(for: trigger) {
            switch action {
            case .selectNext, .selectPrev:
                let delta = action == .selectNext ? 1 : -1
                if showsActions, let item {
                    let count = actions(for: item).count
                    actionIndex = (actionIndex + delta + count) % count
                } else {
                    move(delta, in: items)
                }
                return true
            case .showActions:
                guard item != nil else { return true }
                showsActions.toggle()
                actionIndex = 0
                return true
            case .jumpTo, .copyPath, .copyTarget:
                // With nothing to act on, ⌘C still copies the search text.
                guard let item else { return false }
                let available = actions(for: item)
                if showsActions, action == .jumpTo {
                    perform(available[min(actionIndex, available.count - 1)], on: item)
                } else if available.contains(action) {
                    perform(action, on: item)
                }
                return true
            }
        }
        if let index = Self.commandDigits.firstIndex(of: trigger), chips.indices.contains(index) {
            toggleChip(chips[index])
            return true
        }
        return false
    }

    private func move(_ delta: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[(current + delta + items.count) % items.count].id
        showsActions = false
    }

    private static let escape = KeyTrigger(modifiers: [], key: .special(.escape))
    private static let commandDigits = (1...9).map { KeyTrigger(modifiers: .command, key: .character(Character("\($0)"))) }

    // MARK: Screenshots

    #if DEBUG
    /// Drives an instance into a state without keystrokes, for screenshots of
    /// a build running in the background: post `dev.muxify.palette` with this
    /// process's pid as the object and a `spec` such as
    /// "palette=Sessions;query=mux;down=2;actions=1;action=1;sources=agents,windows",
    /// or "close=1".
    private func observeDemoRequests() {
        demoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.muxify.palette"),
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
        ) { [weak self] note in
            let spec = note.userInfo?["spec"] as? String ?? ""
            MainActor.assumeIsolated { self?.applyDemo(spec) }
        }
    }

    private func applyDemo(_ spec: String) {
        let fields = Dictionary(spec.split(separator: ";").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : parts.first.map { ($0, "") }
        }, uniquingKeysWith: { _, last in last })
        if fields["close"] != nil { close(); return }
        guard let palettes = store?.config.commandPalettes,
              let palette = palettes.first(where: { $0.name == fields["palette"] }) ?? palettes.first else { return }
        if current?.name != palette.name { toggle(palette) }
        if let sources = fields["sources"] {
            selection = Set(sources.split(separator: ",").compactMap { PaletteSource(rawValue: String($0)) })
        }
        query = fields["query"] ?? ""
        for _ in 0..<(Int(fields["down"] ?? "") ?? 0) { move(1, in: results) }
        showsActions = fields["actions"] == "1"
        actionIndex = Int(fields["action"] ?? "") ?? 0
    }
    #endif
}

// MARK: - Theme

/// A Copy's confirmation: "Copied Path" and what was copied.
struct PaletteCopy: Equatable {
    let id = UUID()
    let title: String
    let value: String
}

/// The Sidebar's colors (Ghostty background shaded toward the foreground)
/// plus the Ghostty theme's ANSI colors. System colors without a theme.
struct PaletteTheme {
    let chrome: Color
    let background: Color
    let foreground: Color
    let separator: Color
    let colorScheme: ColorScheme
    private let ansiColors: [Color]

    init(_ theme: TerminalTheme?) {
        if let theme {
            chrome = Color(nsColor: theme.chrome)
            background = Color(nsColor: theme.background)
            foreground = Color(nsColor: theme.foreground)
            separator = Color(nsColor: theme.separator)
            colorScheme = theme.isDark ? .dark : .light
            ansiColors = theme.ansi.map { Color(nsColor: $0) }
        } else {
            chrome = Color(nsColor: .windowBackgroundColor)
            background = Color(nsColor: .textBackgroundColor)
            foreground = Color(nsColor: .labelColor)
            separator = Color(nsColor: .separatorColor)
            colorScheme = .light
            ansiColors = []
        }
    }

    /// ANSI color `index` (0–15), or a system stand-in.
    func ansi(_ index: Int) -> Color {
        if ansiColors.indices.contains(index) { return ansiColors[index] }
        let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
        return index == 8 ? .gray : fallback[index % 8]
    }

    var red: Color { ansi(1) }
    var green: Color { ansi(2) }
    var yellow: Color { ansi(3) }
    var blue: Color { ansi(4) }
    var magenta: Color { ansi(5) }
    var cyan: Color { ansi(6) }

    /// Same meaning as the Sidebar's dots, in the theme's colors.
    func status(_ status: AgentStatus?, unread: Bool) -> Color? {
        switch status {
        case .working: blue
        case .blocked: yellow
        case .failed: red
        case .done: unread ? green : nil
        case nil: nil
        }
    }
}
