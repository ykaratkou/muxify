import SwiftUI

/// App-wide menus act on the focused App Window, never on the last workspace
/// to start a terminal or reconnect.
struct MuxifyCommands: Commands {
    let windows: AppWindows
    private var store: WorkspaceStore? { windows.focusedStore }
    private var configStore: ConfigStore { windows.configStore }
    private var keybinds: Keybinds { configStore.config.keybinds }
    private var remoteActionDisabled: Bool {
        guard let store else { return true }
        return store.isRemote && !store.isConnected
    }

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            // The key monitor acts before the menu; the shortcut is shown here.
            Button(store?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") { store?.toggleSidebar() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleSidebar)?.shortcut)
                .disabled(store == nil)
            Toggle("Show Sessions", isOn: Binding(get: { store?.sessionsVisible ?? true }, set: { store?.sessionsVisible = $0 }))
                .disabled(store == nil)
            Toggle("Show Agents", isOn: Binding(get: { store?.agentsVisible ?? true }, set: { store?.agentsVisible = $0 }))
                .disabled(store == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Muxify Window") { windows.newWindow() }
                .keyboardShortcut(keybinds.firstTrigger(for: .newAppWindow)?.shortcut)
            Divider()
            Button("New Tab") { store?.browserCommand { $0.newTab() } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store == nil)
            Button("New tmux Window") { store?.newWindow() }
                .disabled(remoteActionDisabled)
            Button("New tmux Session") { store?.newSession() }
                .disabled(remoteActionDisabled)
        }
        // Browser shortcuts act outside the terminal; in the terminal the
        // user's Ghostty/tmux bindings own these keys.
        CommandMenu("Browser") {
            Button(store?.currentBrowser?.isOpen == true ? "Hide Browser" : "Show Browser") { store?.toggleBrowser() }
                .keyboardShortcut(keybinds.firstTrigger(for: .toggleBrowser)?.shortcut)
            Button("Open Location…") { store?.browserCommand { _ in store?.focusAddressBar() } }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button("Close Tab") { store?.browserCommand { $0.closeActiveTab() } }
                .keyboardShortcut("w", modifiers: .command)
            Button("Show Next Tab") { store?.browserCommand { $0.selectTab(offset: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { store?.browserCommand { $0.selectTab(offset: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Back") { store?.browserCommand { $0.activeTab?.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { store?.browserCommand { $0.activeTab?.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
            Button("Reload Page") { store?.browserCommand { $0.activeTab?.reloadOrStop() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Focus Terminal") { store?.focusTerminal() }
                .keyboardShortcut("`", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            Button("Open Config") { configStore.openInEditor() }
            Button("Reload Config") { configStore.reload() }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Install Extensions") { ExtensionInstaller.run() }
                .disabled(store?.isRemote == true)
            Button("Install Command Line Tool") { CommandLineToolInstaller.run() }
        }
    }
}
