import SwiftUI

struct ContentView: View {
    let store: WorkspaceStore
    let configStore: ConfigStore
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    /// The Browser's share of the room beside the sidebar, the same for every
    /// Window's Browser. A share rather than a width, so resizing the window
    /// keeps terminal and Browser in proportion.
    @AppStorage("browserShare") private var browserShare: Double = 0.45

    var body: some View {
        GeometryReader { proxy in
            let sidebar = store.sidebarVisible ? clamp(sidebarWidth, 180, 420) : 0
            let room = proxy.size.width - sidebar
            let browserMax = max(320, room - 360)
            let browserWidth = clamp(browserShare * room, 320, browserMax)
            // Panels appear and disappear without animation, so switching
            // between Windows with and without a Browser is instant.
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView(store: store)
                        .frame(width: sidebar)
                        .chrome(theme: store.theme, material: .sidebar)
                    PanelResizeHandle(width: sidebar, range: 180...420, edge: .leading) { sidebarWidth = $0 }
                }
                TerminalArea(store: store)
                if let browser = store.currentBrowser, browser.isOpen {
                    PanelResizeHandle(width: browserWidth, range: 320...browserMax, edge: .trailing) {
                        browserShare = $0 / room
                    }
                    BrowserPanel(browser: browser)
                        .id(browser.windowID)
                        .frame(width: browserWidth)
                }
            }
        }
        .overlay(alignment: .top) {
            if !configStore.problems.isEmpty, !configStore.problemsDismissed {
                ConfigProblemsBanner(configStore: configStore, theme: store.theme)
            }
        }
        .padding(.top, headerHeight)
        // An overlay, so it is above everything for clicks: scroll views below
        // (sidebar list, tab strip) reach up under the title bar area and would
        // otherwise swallow clicks on the toggles.
        .overlay(alignment: .top) {
            HeaderBar(store: store, keybinds: configStore.config.keybinds, height: headerHeight)
        }
        .ignoresSafeArea()
        // Names the window for the Window menu and Mission Control.
        .navigationTitle(store.isRemote
                         ? "\(store.environmentName) — \(store.selectedWindow?.sessionName ?? "Muxify")"
                         : store.selectedWindow?.sessionName ?? "Muxify")
        .onAppear { store.start() }
        .onChange(of: configStore.config.remoteEnvironments) { _, _ in store.reconcileEnvironments() }
    }

    private var headerHeight: CGFloat { CGFloat(configStore.config.headerHeight) }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// The fixed strip along the top: room for the traffic lights, the window's
/// drag handle, Environment selector, and two panel toggles on the right.
private struct HeaderBar: View {
    let store: WorkspaceStore
    let keybinds: Keybinds
    let height: CGFloat

    var body: some View {
        let browserOpen = store.currentBrowser?.isOpen ?? false
        HStack(spacing: 2) {
            Spacer()
            EnvironmentSelector(environments: store.remoteEnvironments, activeEnvironment: store.activeEnvironment,
                                isConnected: store.isConnected, hasConnectionError: store.terminalMessage != nil,
                                status: store.environmentStatus, onSelect: store.selectEnvironment)
            TitlebarButton(
                systemName: "sidebar.left",
                help: help(store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", .toggleSidebar),
                isOn: store.sidebarVisible,
                action: store.toggleSidebar
            )
            TitlebarButton(
                systemName: "sidebar.right",
                help: help(browserOpen ? "Hide Browser" : "Show Browser", .toggleBrowser),
                isOn: browserOpen,
                action: store.toggleBrowser
            )
        }
        .padding(.leading, TitlebarMetrics.trafficLightsWidth)
        .padding(.trailing, 8)
        .frame(height: height)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: store.theme?.separator ?? .separatorColor))
                .frame(height: 1)
        }
        .chrome(theme: store.theme, material: .titlebar)
    }

    private func help(_ title: String, _ action: ConfigAction) -> String {
        keybinds.firstTrigger(for: action).map { "\(title) (\($0.symbol))" } ?? title
    }
}

/// Lists the Config values Muxify skipped, or the syntax error that keeps
/// the last good Config, until the user closes it or the Config reloads.
private struct ConfigProblemsBanner: View {
    let configStore: ConfigStore
    let theme: TerminalTheme?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Problems in the Muxify Config")
                    .font(.callout.weight(.semibold))
                ForEach(Array(configStore.problems.enumerated()), id: \.offset) { _, problem in
                    Text("\((problem.path as NSString).abbreviatingWithTildeInPath):\(problem.line): \(problem.message)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Open Config") { configStore.openInEditor() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
            Button {
                configStore.problemsDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(10)
        .frame(maxWidth: 560)
        .chrome(theme: theme, material: .popover)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: theme?.separator ?? .separatorColor))
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(10)
    }
}

private extension View {
    /// Header and sidebar take their background from the Ghostty theme, and
    /// their text follows its lightness, so a dark theme stays readable while
    /// macOS is in light mode. Without a theme they use the system materials.
    @ViewBuilder
    func chrome(theme: TerminalTheme?, material: NSVisualEffectView.Material) -> some View {
        if let theme {
            background(Color(nsColor: theme.chrome))
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        } else {
            background(VisualEffectBackground(material: material))
        }
    }
}

private struct TerminalArea: View {
    let store: WorkspaceStore
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        ZStack {
            TerminalHostRepresentable(host: store.terminalHost)
            if store.surface == nil { placeholder }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if let message = store.terminalMessage {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                if store.isRemote {
                    Text(store.environmentStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Reconnect") { store.reattach() }
                }
            } else if store.isRemote, !store.isConnected {
                Text(store.environmentStatus).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else if store.windows.isEmpty {
                Text(store.serverRunning ? "No tmux windows" : "tmux server is not running")
                    .foregroundStyle(.secondary)
                Button("New tmux Session") { store.newSession() }
            } else {
                Text("Detached from tmux").foregroundStyle(.secondary)
                Button("Reattach") { store.reattach() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.theme?.background ?? .windowBackgroundColor))
        .environment(\.colorScheme, store.theme.map { $0.isDark ? .dark : .light } ?? systemColorScheme)
    }
}

private struct TerminalHostRepresentable: NSViewRepresentable {
    let host: TerminalHostView

    func makeNSView(context: Context) -> TerminalHostView { host }
    func updateNSView(_ nsView: TerminalHostView, context: Context) {}
}

// MARK: - Title bar controls

enum TitlebarMetrics {
    /// Room to leave on the leading edge for the traffic lights.
    static let trafficLightsWidth: CGFloat = 78
}

struct TitlebarButton: View {
    let systemName: String
    let help: String
    var isOn = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .actsOnFirstClick()
    }
}

private extension View {
    /// Like toolbar buttons: a click on an inactive window both activates it
    /// and presses the button.
    @ViewBuilder
    func actsOnFirstClick() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

/// Empty space that moves the window when dragged, since there is no title
/// bar to grab anymore.
struct WindowDragArea: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            Color.clear
        }
    }
}

/// The divider beside a panel; drag it to resize the panel.
private struct PanelResizeHandle: View {
    /// The panel's width as laid out.
    let width: Double
    let range: ClosedRange<Double>
    /// Which side of the handle the resized panel is on.
    let edge: HorizontalEdge
    /// Receives the dragged width, kept within `range`.
    let resize: (Double) -> Void

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                PanelDivider(
                    onDrag: { translation in
                        let start = startWidth ?? width
                        if startWidth == nil { startWidth = start }
                        let delta = edge == .leading ? translation : -translation
                        resize(min(max(start + delta, range.lowerBound), range.upperBound))
                    },
                    onDragEnded: { startWidth = nil }
                )
                .frame(width: 1 + 2 * PanelDividerView.reach)
            }
            .zIndex(1)
    }
}

/// Native translucent material (the sidebar and title bar look).
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
