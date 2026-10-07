import AppKit
import GhosttyKit
import Observation

/// One process/Config, with independent workspaces and owned connections for
/// each native App Window. Closing a window cleans only that workspace.
@Observable
final class AppWindows {
    let configStore: ConfigStore
    let initialRequest: AppWindowRequest
    private(set) var focusedID: UUID?
    @ObservationIgnored var openWindow: ((AppWindowRequest) -> Void)?
    @ObservationIgnored private var catalog = AppWindowCatalog()
    @ObservationIgnored private var stores: [UUID: WorkspaceStore] = [:]
    @ObservationIgnored private var nativeWindows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var observers: [UUID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var closedIDs = Set<UUID>()

    var focusedStore: WorkspaceStore? { focusedID.flatMap { stores[$0] } }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let remembered = UserDefaults.standard.string(forKey: "selectedEnvironment")
        let name = configStore.config.remoteEnvironments.first { $0.name == remembered }?.name
        initialRequest = AppWindowRequest(environmentName: name)
    }

    deinit {
        for tokens in observers.values { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    func store(for request: AppWindowRequest) -> WorkspaceStore {
        if let store = stores[request.id] { return store }
        let environment = configStore.config.remoteEnvironments.first { $0.name == request.environmentName }
        let store = WorkspaceStore(configStore: configStore, environment: environment)
        // SwiftUI can evaluate a closing scene again after its cleanup finishes.
        // Do not resurrect its reservation or connection.
        if isQuitting || closedIDs.contains(request.id) {
            store.shutdown {}
            return store
        }
        stores[request.id] = store
        catalog.register(request)
        catalog.updateEnvironment(request.id, name: environment?.name)
        store.onSelectEnvironment = { [weak self] name in self?.selectEnvironment(named: name) }
        store.onNewAppWindow = { [weak self] in self?.newWindow() }
        store.shouldConsumeOpenRequests = { [weak self, weak store] in
            guard let self, let store else { return false }
            return self.catalog.window(forEnvironment: store.activeEnvironment?.name)?.id == request.id
        }
        return store
    }

    func newWindow() {
        guard !isQuitting, let openWindow else { return }
        openWindow(catalog.newLocalWindow())
    }

    func selectEnvironment(named name: String?) {
        guard !isQuitting, name == nil || configStore.config.remoteEnvironments.contains(where: { $0.name == name }) else { return }
        guard let openWindow else { return }
        let request = catalog.openEnvironment(named: name)
        if let window = nativeWindows[request.id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            focus(request.id)
        } else {
            openWindow(request)
        }
    }

    /// Unqualified tmux IDs/session names in macOS URLs belong to Local, not
    /// a remote server with possibly identical IDs. Deliver once per process.
    func handle(_ url: URL) {
        guard !isQuitting, url.scheme == "muxify" else { return }
        if url.host == "toggle-browser" { focusedStore?.handle(url); return }
        guard ["select", "open"].contains(url.host ?? ""), openWindow != nil else { return }
        let request = catalog.openEnvironment(named: nil)
        store(for: request).handle(url)
        selectEnvironment(named: nil)
    }

    func register(_ window: NSWindow, for id: UUID) {
        guard !isQuitting, !closedIDs.contains(id), nativeWindows[id] !== window else { return }
        observers[id]?.forEach(NotificationCenter.default.removeObserver)
        nativeWindows[id] = window
        window.tabbingMode = .disallowed
        let center = NotificationCenter.default
        observers[id] = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.focus(id) },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.close(id) },
        ]
        if window.isKeyWindow { focus(id) }
    }

    func updateEnvironment(for id: UUID) {
        guard let store = stores[id] else { return }
        catalog.updateEnvironment(id, name: store.activeEnvironment?.name)
        if focusedID == id { remember(store.activeEnvironment?.name) }
    }

    private func focus(_ id: UUID) {
        guard !isQuitting, let store = stores[id], nativeWindows[id] != nil else { return }
        catalog.focus(id)
        focusedID = id
        remember(store.activeEnvironment?.name)
    }

    private func remember(_ name: String?) {
        if let name { UserDefaults.standard.set(name, forKey: "selectedEnvironment") }
        else { UserDefaults.standard.removeObject(forKey: "selectedEnvironment") }
    }

    private func close(_ id: UUID) {
        closedIDs.insert(id)
        nativeWindows[id] = nil
        catalog.close(id)
        if focusedID == id { focusedID = nil }
        guard let store = stores[id] else { return }
        store.shutdown { [weak self] in
            guard let self else { return }
            self.stores[id] = nil
            self.observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        isQuitting = true
        let pending = DispatchGroup()
        // Closed windows stay in stores until their asynchronous cleanup has
        // finished, so quit also waits for retirement already in flight.
        for store in stores.values {
            pending.enter()
            store.shutdown { pending.leave() }
        }
        pending.notify(queue: .main, execute: completion)
    }
}

extension AppWindows: GhosttyRuntimeDelegate {
    func ghosttyOpenURL(_ url: URL) { focusedStore?.ghosttyOpenURL(url) }
    func ghosttyNewTab() { focusedStore?.ghosttyNewTab() }
    func ghosttyNewWindow() { newWindow() }
    func ghosttyNewSplit(_ direction: ghostty_action_split_direction_e) { focusedStore?.ghosttyNewSplit(direction) }
    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) { focusedStore?.ghosttyGotoSplit(direction) }
    func ghosttyToggleSplitZoom() { focusedStore?.ghosttyToggleSplitZoom() }
    func ghosttyEqualizeSplits() { focusedStore?.ghosttyEqualizeSplits() }
    func ghosttyGotoTab(_ tab: Int32) { focusedStore?.ghosttyGotoTab(tab) }
    func ghosttySurfaceClosed(_ view: TerminalSurfaceView) { view.delegate?.ghosttySurfaceClosed(view) }
    func ghosttyThemeChanged(_ theme: TerminalTheme) { stores.values.forEach { $0.ghosttyThemeChanged(theme) } }
    func ghosttyReloadConfig() { configStore.reload() }
}
