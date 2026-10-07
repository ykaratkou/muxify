import AppKit
import SwiftUI

/// Two sections stacked vertically: Sessions on top, Agents below. Each can be
/// hidden from the View menu; with both shown, a divider between them sets
/// their split. With neither, the sidebar stays open but empty.
struct SidebarView: View {
    let store: WorkspaceStore

    /// The share of the sidebar's height the Agents section gets.
    @AppStorage("sidebarAgentsFraction") private var agentsFraction: Double = 0.35

    var body: some View {
        if store.sessionsVisible && store.agentsVisible {
            GeometryReader { proxy in
                let total = proxy.size.height
                VStack(spacing: 0) {
                    SessionsSection(store: store)
                        .frame(maxHeight: .infinity)
                    SectionResizeHandle(fraction: $agentsFraction, total: total)
                    AgentsSection(store: store)
                        .frame(height: SectionResizeHandle.agentsHeight(agentsFraction, total: total))
                }
            }
        } else if store.sessionsVisible {
            SessionsSection(store: store)
        } else if store.agentsVisible {
            AgentsSection(store: store)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The divider between Sessions and Agents; drag it to move the split.
private struct SectionResizeHandle: View {
    @Binding var fraction: Double
    /// The sidebar's height.
    let total: CGFloat

    /// Neither section gets smaller than this.
    static let minHeight: CGFloat = 90

    @State private var startHeight: CGFloat?

    /// The Agents section's height for `fraction`, keeping both sections usable.
    static func agentsHeight(_ fraction: Double, total: CGFloat) -> CGFloat {
        let high = max(minHeight, total - minHeight)
        return min(max((total * fraction).rounded(), minHeight), high)
    }

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = startHeight ?? Self.agentsHeight(fraction, total: total)
                                if startHeight == nil { startHeight = start }
                                // Dragging up grows Agents.
                                let height = Self.agentsHeight(Double((start - value.translation.height) / total), total: total)
                                fraction = Double(height / total)
                            }
                            .onEnded { _ in startHeight = nil }
                    )
            }
            .zIndex(1)
    }
}

/// The Sessions and their Windows.
private struct SessionsSection: View {
    let store: WorkspaceStore

    /// Expanded sessions, by name (names survive tmux server restarts, ids don't).
    @State private var expanded: Set<String> = Self.loadExpanded()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.sessions) { session in
                            let isExpanded = expanded.contains(session.name)
                            SessionHeader(
                                session: session,
                                isExpanded: isExpanded,
                                containsSelection: session.windows.contains { $0.id == store.selectedWindowID },
                                onToggle: { toggle(session.name) }
                            )
                            if isExpanded {
                                ForEach(session.windows) { window in
                                    WindowRow(
                                        window: window,
                                        isSelected: window.id == store.selectedWindowID,
                                        tabCount: store.tabCount(for: window)
                                    )
                                        .id(window.id)
                                        .onTapGesture { store.select(window) }
                                        .contextMenu { menu(for: window) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onChange(of: store.selectedWindowID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        .overlay {
            if store.windows.isEmpty {
                Text(store.serverRunning ? "No windows" : "No tmux server")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        // Moving to another session (click, tmux navigation, new window) opens it.
        .onChange(of: store.selectedWindow?.sessionName, initial: true) { _, name in
            guard let name, !expanded.contains(name) else { return }
            withAnimation(.easeOut(duration: 0.15)) { _ = expanded.insert(name) }
        }
        .onChange(of: expanded) { _, value in
            UserDefaults.standard.set(Array(value), forKey: Self.expandedKey)
        }
    }

    private static let expandedKey = "expandedSessions"

    private static func loadExpanded() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? [])
    }

    private func toggle(_ name: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }

    @ViewBuilder
    private func menu(for window: TmuxWindow) -> some View {
        Button("Rename Window…") { rename(window) }
        Button("New Window in \(window.sessionName)") { store.newWindow(beside: window) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(window.path, forType: .string)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: window.path)
        }
        .disabled(store.isRemote)
        Divider()
        Button("Kill Window…", role: .destructive) { confirmKill(window) }
    }

    private func rename(_ window: TmuxWindow) {
        let alert = NSAlert()
        alert.messageText = "Rename tmux window"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = window.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.renameWindow(window, to: field.stringValue)
        }
    }

    private func confirmKill(_ window: TmuxWindow) {
        let alert = NSAlert()
        alert.messageText = "Kill \"\(window.displayTitle)\"?"
        alert.informativeText = "This closes tmux window \(window.sessionName):\(window.index) and every process in its \(window.paneCount) pane(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill Window")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.killWindow(window)
        }
    }
}

private struct SessionHeader: View {
    let session: SessionGroup
    let isExpanded: Bool
    let containsSelection: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Text(session.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !isExpanded, session.windows.contains(where: \.hasBell) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .padding(.top, 1)
    }

    /// A collapsed session hiding the current window still shows where you are.
    private var highlighted: Bool { containsSelection && !isExpanded }

    private var background: Color {
        if highlighted { return Color.accentColor.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

private struct WindowRow: View {
    let window: TmuxWindow
    let isSelected: Bool
    let tabCount: Int

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Logo(name: window.logoName)
            Text(window.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if window.hasBell {
                Circle()
                    .fill(isSelected ? Color.white : Color.orange)
                    .frame(width: 5, height: 5)
            }
            if tabCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "globe")
                    Text("\(tabCount)")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryStyle)
                .help("\(tabCount) browser tab(s)")
            }
            if window.paneCount > 1 {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.2x1")
                    Text("\(window.paneCount)")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryStyle)
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help("\(window.sessionName):\(window.index) — \(window.abbreviatedPath)")
    }

    private var secondaryStyle: Color {
        isSelected ? Color.white.opacity(0.85) : Color.secondary
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}

/// The Agents reporting their Status (ADR 0004), in tmux order.
private struct AgentsSection: View {
    let store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)
            if store.agents.isEmpty {
                Text("No agents")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.agents) { agent in
                            AgentRow(agent: agent)
                                .onTapGesture { store.select(agent) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentRow: View {
    let agent: Agent

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Logo(name: agent.kind.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.windowTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(agent.location)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let color = agent.dotColor {
                StatusDot(color: color, breathes: agent.status == .working)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help("\(agent.kind.displayName) — \(agent.status?.rawValue ?? "no status yet")\(agent.unread ? ", unread" : "")")
    }
}

/// An Agent's Status dot. A working Agent's dot breathes, fading to a third
/// and shrinking a little every 1.6s, so movement always means busy. Every
/// working dot reads the same clock, so they breathe together.
private struct StatusDot: View {
    let color: Color
    let breathes: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: TimeInterval = 1.6

    var body: some View {
        if breathes, !reduceMotion {
            // 30 fps is plenty for a slow fade, and Agents can work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let wave = cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / Self.period)
                dot
                    .opacity(0.675 + 0.325 * wave)
                    .scaleEffect(0.89 + 0.11 * wave)
            }
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// A program's logo from `Resources/Logos` (`<name>.svg` or `<name>.png`),
/// or the terminal logo when there is none. On a dark theme `<name>.dark.svg`
/// wins when there is one; black-only logos without one are drawn in the text
/// color so they stay visible.
private struct Logo: View {
    let name: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = (colorScheme == .dark ? Self.image(name + ".dark") : nil) ?? Self.image(name) ?? Self.image("terminal") {
                Image(nsImage: image)
                    .renderingMode(Self.monochrome.contains(name) ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 14, height: 14)
    }

    private static let monochrome: Set<String> = ["pi"]
    /// Looked up once per name; nil when the bundle has no logo for it.
    private static var cache: [String: NSImage?] = [:]

    private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let url = name.isEmpty ? nil : ["svg", "png"].lazy
            .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        let image = url.flatMap(NSImage.init(contentsOf:))
        cache[name] = image
        return image
    }
}

private extension Agent {
    /// Working blue, blocked orange, failed red, done green while unread.
    /// A read Agent that is done (or hasn't run a turn) gets no dot.
    var dotColor: Color? {
        switch status {
        case .working: return .blue
        case .blocked: return .orange
        case .failed: return .red
        case .done: return unread ? .green : nil
        case nil: return nil
        }
    }
}
