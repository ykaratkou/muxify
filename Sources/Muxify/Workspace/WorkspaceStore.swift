import AppKit
import GhosttyKit
import Observation

struct SessionGroup: Identifiable {
    let id: String
    let name: String
    var windows: [TmuxWindow]
}

/// App state: the tmux Windows in the sidebar, the one libghostty surface
/// running our tmux client, and a Browser per Window.
///
/// The terminal is a single `tmux attach` client attached straight to your
/// Sessions. Clicking a sidebar Window runs `switch-client -c <our tty> -t
/// <window>`, so tmux renders it with all its Panes, and anything you do
/// inside tmux (prefix+n, choose-tree, …) is reflected back into the sidebar.
@MainActor @Observable
final class WorkspaceStore {
    private(set) var windows: [TmuxWindow] = []
    /// Agents reporting through their Pane's options (ADR 0004), in tmux order.
    private(set) var agents: [Agent] = []
    private(set) var serverRunning = true
    private(set) var selectedWindowID: String? {
        didSet { rememberSelection() }
    }
    private(set) var surface: TerminalSurfaceView?
    private(set) var terminalMessage: String?
    private(set) var activeEnvironment: RemoteEnvironment?
    private(set) var environmentStatus = "Local"
    private(set) var isConnected = false
    var remoteEnvironments: [RemoteEnvironment] { configStore.config.remoteEnvironments }
    var isRemote: Bool { activeEnvironment != nil }
    var environmentName: String { activeEnvironment?.name ?? "Local" }
    /// The Ghostty theme's colors; the header and sidebar follow them.
    private(set) var theme: TerminalTheme?

    var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }
    /// The sidebar's two sections, shown or hidden from the View menu.
    var sessionsVisible = UserDefaults.standard.object(forKey: "sessionsVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sessionsVisible, forKey: "sessionsVisible") }
    }
    var agentsVisible = UserDefaults.standard.object(forKey: "agentsVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(agentsVisible, forKey: "agentsVisible") }
    }

    var selectedWindow: TmuxWindow? {
        guard let selectedWindowID else { return nil }
        return windows.first { $0.id == selectedWindowID }
    }

    var sessions: [SessionGroup] {
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

    @ObservationIgnored let terminalHost = TerminalHostView()
    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let events = TmuxEvents()
    @ObservationIgnored private var browsers: [String: Browser] = [:]
    @ObservationIgnored private var persistWork: [String: DispatchWorkItem] = [:]
    /// Keep changes dirty until tmux confirms the write, including commands
    /// already submitted when a window closes. Never flush unchanged Browsers
    /// over newer state saved by another App Window.
    @ObservationIgnored private var dirtyBrowsers: [String: UUID] = [:]
    /// Windows whose `@muxify_open` we consumed and are clearing.
    @ObservationIgnored private var consumingOpen = Set<String>()
    @ObservationIgnored private var rememberedWindowID: String?
    @ObservationIgnored private var clientTTY: String?
    /// A click we sent to tmux that the next snapshots may not reflect yet.
    @ObservationIgnored private var pendingSelection: (windowID: String, deadline: Date)?
    /// A Session asked for by name (`muxify session open`) that the snapshot
    /// may not list yet: Muxify is just launching, or it was just created.
    @ObservationIgnored private var pendingSession: (name: String, deadline: Date)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var isRefreshing = false
    /// Something changed while a snapshot was in flight; take another one.
    @ObservationIgnored private var refreshAgain = false
    /// Each Pane's `@muxify_agent_status` in the last snapshot, to catch changes.
    @ObservationIgnored private var agentStatuses: [String: String] = [:]
    @ObservationIgnored private var activationObserver: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var connection: TmuxConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isTransitioning = false
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private var homeDirectory = NSHomeDirectory()
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let connectionCleanup = ConnectionCleanup()
    @ObservationIgnored var onSelectEnvironment: ((String?) -> Void)?
    @ObservationIgnored var onNewAppWindow: (() -> Void)?
    @ObservationIgnored var shouldConsumeOpenRequests: (() -> Bool)?

    init(configStore: ConfigStore, environment: RemoteEnvironment? = nil) {
        self.configStore = configStore
        activeEnvironment = environment
        // Browser state used to be kept here, keyed by window id; it now lives
        // on the tmux Windows (ADR 0003).
        UserDefaults.standard.removeObject(forKey: "browserURLs")
        UserDefaults.standard.removeObject(forKey: "browserVisible")
        // Replaced by browserShare, so the Browser scales with the window.
        UserDefaults.standard.removeObject(forKey: "browserWidth")
    }

    func start() {
        guard !started, !isShuttingDown else { return }
        started = true
        theme = GhosttyRuntime.shared.theme
        guard GhosttyRuntime.shared.app != nil else {
            terminalMessage = "libghostty failed to initialize."
            return
        }
        installKeyMonitor()
        // Coming back to Muxify reads the Agents in the Window on screen.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        startConnection()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Environments

    func selectEnvironment(named name: String?) {
        guard !isShuttingDown else { return }
        onSelectEnvironment?(name)
    }

    func reconcileEnvironments() {
        guard let activeEnvironment else { return }
        let next = remoteEnvironments.first { $0.name == activeEnvironment.name }
        if next != activeEnvironment { transition(to: next) }
    }

    /// Reconnect after transport/config changes. Environment clicks instead
    /// open or focus another App Window through the app coordinator.
    private func transition(to next: RemoteEnvironment?) {
        guard !isShuttingDown else { return }
        activeEnvironment = next
        generation = UUID()
        reconnectWork?.cancel()
        reconnectWork = nil
        isConnected = false
        environmentStatus = next == nil ? "Switching to Local" : "Connecting to \(next!.name)…"
        terminalMessage = nil
        guard !isTransitioning else { return }
        isTransitioning = true
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserCommands
        events.stop()
        surface = nil
        terminalHost.show(nil)
        clearServerState()
        connection = nil
        connectionCleanup.run(retire: { oldConnection?.retire(flushing: flush) },
                              closeSurface: { oldSurface?.close() },
                              cleanup: { oldConnection?.cleanup() }) { [weak self] in
            guard let self else { return }
            self.isTransitioning = false
            guard self.started, !self.isShuttingDown else { return }
            self.startConnection()
        }
    }

    private func startConnection() {
        guard !isTransitioning else { return }
        if !isRemote, Tmux.binary == nil {
            terminalMessage = "tmux was not found. Install it with `brew install tmux`."
            environmentStatus = "Local tmux was not found"
            return
        }
        do { connection = try TmuxConnection(environment: activeEnvironment) }
        catch {
            terminalMessage = String(describing: error)
            environmentStatus = "Could not start \(environmentName)"
            return
        }
        let current = generation
        events.onEvent = { [weak self] event in
            guard let self, self.generation == current else { return }
            self.handle(event)
        }
        if isRemote {
            environmentStatus = "Connecting to \(environmentName)…"
            attach(to: nil)
        } else {
            environmentStatus = "Local"
            isConnected = true
            refresh(attachIfNeeded: true)
        }
    }

    private func clearServerState() {
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        dirtyBrowsers.removeAll()
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        consumingOpen.removeAll()
        agentStatuses.removeAll()
        windows = []
        agents = []
        selectedWindowID = nil
        rememberedWindowID = nil
        clientTTY = nil
        serverID = nil
        pendingSelection = nil
        pendingSession = nil
        isRefreshing = false
        refreshAgain = false
        serverRunning = false
        homeDirectory = NSHomeDirectory()
    }

    /// Called before AppKit commits to quitting. Snapshot UI-owned Browser
    /// state here, then wait asynchronously for every owned transport to close.
    func shutdown(completion: @escaping () -> Void) {
        guard !isShuttingDown else { connectionCleanup.whenFinished(completion); return }
        isShuttingDown = true
        started = false
        generation = UUID()
        timer?.invalidate()
        timer = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        events.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserCommands
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        dirtyBrowsers.removeAll()
        connection = nil
        surface = nil
        terminalHost.show(nil)
        connectionCleanup.run(retire: { oldConnection?.retire(flushing: flush) },
                              closeSurface: { oldSurface?.close() },
                              cleanup: { oldConnection?.cleanup() })
        connectionCleanup.whenFinished(completion)
    }

    /// Every completion belongs to the connection that submitted it, never to
    /// whatever Environment happens to be selected when it finishes.
    private func runAsync(_ args: [String], completion: ((Result<String, Error>) -> Void)? = nil) {
        guard let connection, !isTransitioning, !isRemote || isConnected else { return }
        let current = generation
        connection.runAsync(args) { [weak self] result in
            guard let self, self.generation == current else { return }
            if case .failure(let error) = result { NSLog("muxify: tmux command failed: \(error)") }
            completion?(result)
        }
    }

    // MARK: - Polling

    func refresh(attachIfNeeded: Bool = false) {
        guard let connection, !isTransitioning else { return }
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try connection.snapshot() }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    if self.isRemote {
                        self.clientTTY = snapshot.ownClientTTY
                        self.homeDirectory = snapshot.homeDirectory ?? self.homeDirectory
                        self.isConnected = true
                        self.environmentStatus = "Connected to \(self.environmentName)"
                        self.reconnectAttempt = 0
                        self.terminalMessage = nil
                    }
                    self.apply(snapshot, attachIfNeeded: attachIfNeeded)
                case .failure(let error):
                    self.isConnected = false
                    if error as? TmuxError != .notReady {
                        self.environmentStatus = "Waiting for \(self.environmentName): \(error)"
                    }
                }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// tmux told us something changed. A Window switch in the Session we are
    /// showing moves the selection right away; the snapshot fills in the rest.
    private func handle(_ event: TmuxEvents.Event) {
        if case .sessionWindowChanged(let sessionID, let windowID) = event,
           pendingSelection == nil, selectedWindow?.sessionID == sessionID,
           windows.contains(where: { $0.id == windowID }) {
            selectedWindowID = windowID
        }
        refresh()
    }

    private func apply(_ snapshot: TmuxSnapshot, attachIfNeeded: Bool) {
        if let serverID, let next = snapshot.serverID, serverID != next {
            clearServerState()
            clientTTY = snapshot.ownClientTTY
            homeDirectory = snapshot.homeDirectory ?? NSHomeDirectory()
        }
        serverID = snapshot.serverID
        if serverRunning, !snapshot.serverRunning {
            browsers.values.forEach { $0.tearDown() }
            browsers.removeAll()
            persistWork.values.forEach { $0.cancel() }
            persistWork.removeAll()
            dirtyBrowsers.removeAll()
        }
        if windows != snapshot.windows { windows = snapshot.windows }
        let agents = snapshot.agents
        if self.agents != agents { self.agents = agents }
        if serverRunning != snapshot.serverRunning { serverRunning = snapshot.serverRunning }

        if attachIfNeeded, surface == nil {
            rememberedWindowID = snapshot.lastWindowID
            let last = snapshot.lastWindowID.flatMap { id in snapshot.windows.first { $0.id == id } }
            let requested = takePendingSession(in: snapshot.windows)
            attach(to: (requested ?? last ?? Self.initialWindow(in: snapshot.windows)).map(Target.init))
        } else {
            followClient(snapshot.clients)
            if surface != nil, let window = takePendingSession(in: windows) { select(window) }
        }
        consumeOpenRequests()
        updateUnread(snapshot.panes)

        // (Re)start listening once there is a Session to attach to.
        if snapshot.serverRunning, !events.isRunning,
           let sessionID = selectedWindow?.sessionID ?? windows.first?.sessionID {
            if let connection { events.start(sessionID: sessionID, connection: connection) }
        }

        if snapshot.serverRunning {
            let live = Set(windows.map(\.id))
            for id in browsers.keys where !live.contains(id) {
                browsers[id]?.tearDown()
                browsers[id] = nil
                dirtyBrowsers[id] = nil
                persistWork.removeValue(forKey: id)?.cancel()
            }
        }
    }

    /// The sidebar follows whatever window our tmux client is showing.
    private func followClient(_ clients: [TmuxClient]) {
        if clientTTY == nil, !isRemote { clientTTY = surface?.ttyName }
        if let tty = clientTTY, let client = clients.first(where: { $0.tty == tty }) {
            if let pending = pendingSelection, client.windowID == pending.windowID || Date() > pending.deadline {
                pendingSelection = nil
            }
            if pendingSelection == nil, selectedWindowID != client.windowID {
                selectedWindowID = client.windowID
            }
        } else if surface == nil, let selectedWindowID, !windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
        }
    }

    /// The current window of the most recently used Session.
    private static func initialWindow(in windows: [TmuxWindow]) -> TmuxWindow? {
        windows.filter(\.isActive).max { $0.sessionActivity < $1.sessionActivity } ?? windows.first
    }

    /// Stored server-wide in tmux rather than in preferences, so it can't
    /// outlive the server and point at a reused window id.
    private func rememberSelection() {
        guard let selectedWindowID, selectedWindowID != rememberedWindowID else { return }
        rememberedWindowID = selectedWindowID
        runAsync(["set-option", "-gq", Tmux.lastWindowOption, selectedWindowID])
    }

    // MARK: - Terminal

    private struct Target {
        let sessionID: String
        let windowID: String
        let path: String?

        init(_ window: TmuxWindow) {
            self.init(sessionID: window.sessionID, windowID: window.id, path: window.path)
        }

        init(sessionID: String, windowID: String, path: String?) {
            self.sessionID = sessionID
            self.windowID = windowID
            self.path = path
        }

        var tmuxTarget: String { "\(sessionID):\(windowID)" }
    }

    /// Starts our tmux client on `target`, or a fresh session if there is none.
    private func attach(to target: Target?) {
        let args = target.map { ["-u", "attach-session", "-t", $0.tmuxTarget] }
            ?? ["-u", "new-session", "-A", "-s", "main", "-c", NSHomeDirectory()]
        guard let connection, let command = try? connection.terminalCommand(args, target: target?.tmuxTarget),
              let view = TerminalSurfaceView(command: command, workingDirectory: isRemote ? nil : target?.path, delegate: self)
        else {
            terminalMessage = "Could not start the terminal."
            return
        }
        surface?.close()
        surface = view
        clientTTY = nil
        terminalMessage = nil
        selectedWindowID = target?.windowID
        if let target { pendingSelection = (target.windowID, Date().addingTimeInterval(3)) }
        terminalHost.show(view)
        focusTerminal()
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == current else { return }
            self.refresh()
        }
    }

    func reattach() {
        if isRemote { reconnectAttempt = 0; transition(to: activeEnvironment); return }
        attach(to: (selectedWindow ?? Self.initialWindow(in: windows)).map(Target.init))
    }

    func select(_ window: TmuxWindow) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        switchClient(to: Target(window))
    }

    /// Shared by Muxify keybinds and Ghostty's tab actions. Only the selected
    /// Session's Windows participate, in the same order as the Sidebar.
    private func navigateWindows(_ navigation: WindowNavigation) {
        guard let current = selectedWindow else { return }
        let siblings = windows.filter { $0.sessionID == current.sessionID }
        guard let currentIndex = siblings.firstIndex(of: current),
              let targetIndex = navigation.targetIndex(currentIndex: currentIndex, count: siblings.count)
        else { return }
        select(siblings[targetIndex])
    }

    /// Shows the Session's current Window (`muxify session open <name>`).
    func selectSession(named name: String) {
        pendingSession = (name, Date().addingTimeInterval(5))
        // Before the terminal exists, the first snapshot attaches to it.
        guard started, surface != nil else { return }
        if let window = takePendingSession(in: windows) { select(window) } else { refresh() }
    }

    /// The requested Session's current Window once a snapshot lists it. The
    /// request is dropped when found, or after a few seconds.
    private func takePendingSession(in windows: [TmuxWindow]) -> TmuxWindow? {
        guard let pending = pendingSession else { return nil }
        let window = windows.first { $0.sessionName == pending.name && $0.isActive }
            ?? windows.first { $0.sessionName == pending.name }
        if window != nil || Date() > pending.deadline { pendingSession = nil }
        return window
    }

    /// Switches to the Agent's Window with its Pane active. The Pane is
    /// selected first (tmux commands run in order) so the Window shows up
    /// with the Agent already focused.
    func select(_ agent: Agent) {
        guard agents.contains(where: { $0.id == agent.id && $0.sourceID == agent.sourceID }) else { return }
        runAsync(["select-pane", "-t", agent.paneID])
        if let window = windows.first(where: { $0.id == agent.windowID }) {
            select(window)
        } else {
            switchClient(to: Target(sessionID: agent.sessionID, windowID: agent.windowID, path: nil))
        }
    }

    /// An Agent becomes unread when it reaches done, failed or blocked while
    /// you aren't looking at its Window (selected, with Muxify in front), and
    /// read again once you are. The flag is a Pane option, so it outlives a
    /// relaunch; it goes when the Agent does.
    private func updateUnread(_ panes: [TmuxPane]) {
        let lookingAt = NSApp.isActive && terminalHost.window?.isKeyWindow == true ? selectedWindowID : nil
        var commands: [[String]] = []
        for pane in panes {
            let previous = agentStatuses[pane.id]
            agentStatuses[pane.id] = pane.agentStatus
            let isAgent = Agent.runs(in: pane)
            if pane.unread {
                if !isAgent || pane.windowID == lookingAt {
                    commands.append(["set-option", "-pqu", "-t", pane.id, Tmux.agentUnreadOption])
                }
            } else if isAgent, pane.windowID != lookingAt, let previous, previous != pane.agentStatus,
                      AgentStatus(rawValue: pane.agentStatus)?.needsAttention == true {
                commands.append(["set-option", "-pq", "-t", pane.id, Tmux.agentUnreadOption, "1"])
            }
        }
        let live = Set(panes.map(\.id))
        agentStatuses = agentStatuses.filter { live.contains($0.key) }
        guard !commands.isEmpty else { return }
        runAsync(Array(commands.joined(separator: [";"]))) { [weak self] _ in self?.refresh() }
    }

    private func switchClient(to target: Target) {
        guard !isTransitioning, !isRemote || isConnected else { return }
        selectedWindowID = target.windowID
        pendingSelection = (target.windowID, Date().addingTimeInterval(isRemote ? 10 : 2))
        focusTerminal()
        guard let surface, !surface.processExited, let tty = clientTTY ?? (isRemote ? nil : surface.ttyName) else {
            if isRemote { return }
            attach(to: target)
            return
        }
        clientTTY = tty
        runAsync(["switch-client", "-c", tty, "-t", target.tmuxTarget]) { [weak self] _ in self?.refresh() }
    }

    var isTerminalFocused: Bool {
        guard let surface else { return false }
        return surface.window?.firstResponder === surface
    }

    /// Keyboard focus is in the current Window's Browser (its page or omnibox).
    var isBrowserFocused: Bool {
        !isTerminalFocused && isBrowserVisible
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let surface = self?.surface else { return }
            surface.window?.makeFirstResponder(surface)
        }
    }

    // MARK: - tmux commands

    func newWindow(beside window: TmuxWindow) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        newWindow(inSession: window.sessionID)
    }

    func newWindow(inSession sessionID: String? = nil) {
        guard let sessionID = sessionID ?? selectedWindow?.sessionID ?? windows.first?.sessionID,
              let sibling = selectedWindow?.sessionID == sessionID ? selectedWindow : windows.first(where: { $0.sessionID == sessionID })
        else {
            newSession()
            return
        }
        // -d, then switch only our client: other Sessions' current windows stay put.
        let args = ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(sessionID):", "-c", sibling.path]
        runAsync(args) { [weak self] result in
            guard let self, case .success(let output) = result else { return }
            let windowID = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.switchClient(to: Target(sessionID: sessionID, windowID: windowID, path: sibling.path))
        }
    }

    func newSession() {
        let cwd = selectedWindow?.path ?? homeDirectory
        var args = ["new-session", "-d", "-P", "-F", "#{session_id}:#{window_id}", "-c", cwd]
        let name = (cwd as NSString).lastPathComponent.replacingOccurrences(of: ".", with: "_")
        if !name.isEmpty, !windows.contains(where: { $0.sessionName == name }) { args += ["-s", name] }
        runAsync(args) { [weak self] result in
            guard let self, case .success(let output) = result else { return }
            let ids = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
            guard ids.count == 2 else { return }
            self.switchClient(to: Target(sessionID: ids[0], windowID: ids[1], path: cwd))
        }
    }

    func killWindow(_ window: TmuxWindow) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        runAsync(["kill-window", "-t", window.id]) { [weak self] _ in self?.refresh() }
    }

    func renameWindow(_ window: TmuxWindow, to name: String) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        runAsync(["rename-window", "-t", window.id, name]) { [weak self] _ in self?.refresh() }
    }

    /// Runs a tmux command against the pane our client currently has focused.
    private func runOnCurrentPane(_ makeArgs: @escaping (_ paneID: String, _ windowID: String) -> [String]) {
        // display-message's -c is a message recipient, not a dependable format
        // context. Another client (including the event listener) may otherwise
        // supply its current Pane. Window selection is queued before this call.
        guard let windowID = selectedWindowID else { return }
        runAsync(["display-message", "-p", "-t", windowID, "#{pane_id} #{window_id}"]) { [weak self] result in
            guard case .success(let output) = result else { return }
            let ids = output.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard ids.count == 2 else { return }
            self?.runAsync(makeArgs(ids[0], ids[1])) { _ in self?.refresh() }
        }
    }

    // MARK: - Browser

    var isBrowserVisible: Bool { currentBrowser?.isOpen == true }

    /// The Window's Browser, restored from its tmux options on first use.
    func browser(for windowID: String) -> Browser {
        if let browser = browsers[windowID] { return browser }
        let stored = windows.first { $0.id == windowID }?.storedBrowser ?? StoredBrowser()
        let browser = Browser(windowID: windowID, stored: stored, discoversLocalServers: !isRemote)
        let current = generation
        browser.onChange = { [weak self] browser in
            guard let self, self.generation == current else { return }
            persistWindow(browser.windowID)
        }
        browsers[windowID] = browser
        return browser
    }

    var currentBrowser: Browser? {
        selectedWindowID.map(browser(for:))
    }

    /// For the sidebar badge, without restoring Browsers nobody has looked at.
    func tabCount(for window: TmuxWindow) -> Int {
        browsers[window.id]?.tabs.count ?? window.storedBrowser.tabURLs.count
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func setBrowserOpen(_ open: Bool) {
        currentBrowser?.setOpen(open)
        if !open { focusTerminal() }
    }

    func toggleBrowser() {
        setBrowserOpen(!isBrowserVisible)
    }

    func focusAddressBar() {
        guard let browser = currentBrowser else { return }
        setBrowserOpen(true)
        browser.wantsAddressFocus = true
    }

    /// Menu actions for the Browser. Their shortcuts only count when focus is
    /// outside the terminal, where Ghostty/tmux bindings own the keyboard;
    /// clicking the menu item always works.
    func browserCommand(opensBrowser: Bool = false, _ body: (Browser) -> Void) {
        if NSApp.currentEvent?.type == .keyDown, isTerminalFocused { return }
        if NSApp.currentEvent?.type == .keyDown, !opensBrowser, !isBrowserVisible { return }
        guard let browser = currentBrowser else { return }
        let wasBrowserVisible = isBrowserVisible
        body(browser)
        if !browser.isOpen, wasBrowserVisible { focusTerminal() }
    }

    /// Opens `url` as a Tab in a Window's Browser (the current Window by
    /// default). For another Window it happens quietly: you aren't moved.
    func openInBrowser(_ url: URL, windowID: String? = nil) {
        guard let id = windowID ?? selectedWindowID else {
            NSWorkspace.shared.open(url)
            return
        }
        browser(for: id).open(url)
    }

    /// Programs inside a Window open Tabs with
    /// `tmux set -w -t "$TMUX_PANE" @muxify_open <url>` (several URLs may be
    /// space-separated); we open them and clear the option.
    private func consumeOpenRequests() {
        // Several Local App Windows can see the same tmux option. Only one
        // should consume it, not open duplicate Tabs in every Browser view.
        guard shouldConsumeOpenRequests?() ?? true else { return }
        for window in windows where !window.openRequests.isEmpty && !consumingOpen.contains(window.id) {
            consumingOpen.insert(window.id)
            for request in window.openRequests {
                if let url = Omnibox.url(for: request) { openInBrowser(url, windowID: window.id) }
            }
            runAsync(["set-option", "-wqu", "-t", window.id, Tmux.openOption]) { [weak self] _ in
                self?.consumingOpen.remove(window.id)
            }
        }
    }

    /// Writes Browser state onto its tmux Window, coalescing bursts of
    /// changes (redirects, quick Tab switching) into one tmux call.
    private func persistWindow(_ id: String) {
        guard !isShuttingDown else { return }
        let current = generation
        let revision = UUID()
        dirtyBrowsers[id] = revision
        persistWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current, let browser = self.browsers[id] else { return }
            self.persistWork[id] = nil
            self.runAsync(browser.stored.setOptionArgs(windowID: id)) { [weak self] result in
                guard let self, case .success = result, self.dirtyBrowsers[id] == revision else { return }
                self.dirtyBrowsers[id] = nil
            }
        }
        persistWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    var pendingBrowserCommands: [[String]] {
        dirtyBrowsers.keys.sorted().compactMap { id in browsers[id]?.stored.setOptionArgs(windowID: id) }
    }

    // MARK: - Keyboard

    private func perform(_ action: ConfigAction) {
        switch action {
        case .newAppWindow: onNewAppWindow?()
        case .toggleSidebar: toggleSidebar()
        case .toggleBrowser: toggleBrowser()
        case .selectWindow1: navigateWindows(.position(1))
        case .selectWindow2: navigateWindows(.position(2))
        case .selectWindow3: navigateWindows(.position(3))
        case .selectWindow4: navigateWindows(.position(4))
        case .selectWindow5: navigateWindows(.position(5))
        case .selectWindow6: navigateWindows(.position(6))
        case .selectWindow7: navigateWindows(.position(7))
        case .selectWindow8: navigateWindows(.position(8))
        case .selectWindow9: navigateWindows(.position(9))
        case .selectNextWindow: navigateWindows(.next)
        case .selectPrevWindow: navigateWindows(.previous)
        }
    }

    /// The Config's keybinds, which act before the terminal, Browser and menu
    /// see the key, so they win over Ghostty and page keybinds. Then shortcuts
    /// the menu can't express: ⌘W closes a Tab when the Browser has focus and
    /// never the app window (which would quit Muxify); ⌃Tab and ⌃⇧Tab switch Tabs.
    /// Other keys in the terminal are left to Ghostty/tmux bindings.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !isShuttingDown, let window = terminalHost.window, event.window === window else { return event }
        if let trigger = KeyTrigger(event) {
            let keybinds = configStore.config.keybinds
            if let action = keybinds.action(for: trigger) {
                perform(action)
                return nil
            }
            if keybinds.suppressesDefaultAppWindowShortcut(trigger) { return nil }
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command, key == "w" {
            if isBrowserFocused { browserCommand { $0.closeActiveTab() } }
            return nil
        }
        if event.keyCode == 0x30, flags == .control || flags == [.control, .shift], isBrowserFocused {
            currentBrowser?.selectTab(offset: flags.contains(.shift) ? -1 : 1)
            return nil
        }
        return event
    }
}

// MARK: - muxify:// URLs

extension WorkspaceStore {
    /// Scriptable entry points, e.g. from a shell inside tmux:
    ///   open "muxify://open?url=localhost:3000&window=$(tmux display -p '#{window_id}')"
    ///   open "muxify://select?window=@12"
    ///   open "muxify://toggle-browser"
    func handle(_ url: URL) {
        guard url.scheme == "muxify" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch url.host {
        case "select":
            if let id = value("window") {
                if let window = windows.first(where: { $0.id == id }) { select(window) }
            } else if let name = value("session") {
                selectSession(named: name)
            }
        case "open":
            guard let input = value("url"), let target = Omnibox.url(for: input) else { return }
            openInBrowser(target, windowID: value("window"))
        case "toggle-browser":
            toggleBrowser()
        default:
            NSLog("muxify: unknown URL \(url)")
        }
    }
}

// MARK: - libghostty actions

extension WorkspaceStore: @preconcurrency GhosttyRuntimeDelegate {
    func ghosttyOpenURL(_ url: URL) {
        // Cmd+click on a link in the terminal opens it as a Tab in this Window's Browser.
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            openInBrowser(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func ghosttyThemeChanged(_ theme: TerminalTheme) {
        self.theme = theme
    }

    func ghosttyReloadConfig() {
        configStore.reload()
    }

    func ghosttyNewTab() { newWindow() }
    func ghosttyNewWindow() { onNewAppWindow?() }

    func ghosttyNewSplit(_ direction: ghostty_action_split_direction_e) {
        let flags: [String]
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: flags = ["-h", "-b"]
        case GHOSTTY_SPLIT_DIRECTION_DOWN: flags = ["-v"]
        case GHOSTTY_SPLIT_DIRECTION_UP: flags = ["-v", "-b"]
        default: flags = ["-h"]
        }
        runOnCurrentPane { pane, _ in ["split-window"] + flags + ["-t", pane, "-c", "#{pane_current_path}"] }
    }

    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: runOnCurrentPane { _, window in ["select-pane", "-t", "\(window).-"] }
        case GHOSTTY_GOTO_SPLIT_NEXT: runOnCurrentPane { _, window in ["select-pane", "-t", "\(window).+"] }
        case GHOSTTY_GOTO_SPLIT_UP: runOnCurrentPane { pane, _ in ["select-pane", "-U", "-t", pane] }
        case GHOSTTY_GOTO_SPLIT_DOWN: runOnCurrentPane { pane, _ in ["select-pane", "-D", "-t", pane] }
        case GHOSTTY_GOTO_SPLIT_LEFT: runOnCurrentPane { pane, _ in ["select-pane", "-L", "-t", pane] }
        default: runOnCurrentPane { pane, _ in ["select-pane", "-R", "-t", pane] }
        }
    }

    func ghosttyToggleSplitZoom() {
        runOnCurrentPane { pane, _ in ["resize-pane", "-Z", "-t", pane] }
    }

    func ghosttyEqualizeSplits() {
        runOnCurrentPane { pane, _ in ["select-layout", "-E", "-t", pane] }
    }

    func ghosttyGotoTab(_ tab: Int32) {
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: navigateWindows(.previous)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: navigateWindows(.next)
        case GHOSTTY_GOTO_TAB_LAST.rawValue: navigateWindows(.last)
        default: navigateWindows(.position(Int(tab)))
        }
    }

    func ghosttySurfaceClosed(_ view: TerminalSurfaceView) {
        guard view === surface else {
            view.close()
            return
        }
        // A close request (e.g. cmd+w) while tmux is still attached: keep the client.
        guard view.processExited else { return }
        view.close()
        surface = nil
        clientTTY = nil
        terminalHost.show(nil)
        if let remote = connection?.remote {
            events.stop()
            isConnected = false
            let message = remote.failureMessage
            if remote.exitStatus == 0 {
                environmentStatus = "Detached from \(environmentName)"
                terminalMessage = "Detached from remote tmux."
            } else {
                environmentStatus = "Disconnected from \(environmentName)"
                terminalMessage = message.isEmpty ? "SSH connection closed." : message
            }
            if remote.shouldReconnect {
                let delay = min(pow(2, Double(min(reconnectAttempt, 5))), 30)
                reconnectAttempt += 1
                environmentStatus += ". Reconnecting in \(Int(delay))s…"
                let current = generation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.transition(to: self.activeEnvironment)
                }
                reconnectWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            return
        }
        refresh()
    }
}

/// Plain AppKit container the SwiftUI layout embeds; the terminal surface view
/// is swapped in and out of it without SwiftUI recreating anything.
final class TerminalHostView: NSView {
    private weak var current: NSView?

    func show(_ view: NSView?) {
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}
