import SwiftUI

/// Hosts the Command Palette and its "Copied" pill over the App Window.
struct CommandPaletteOverlay: View {
    let palette: CommandPalette

    var body: some View {
        // Fills the App Window even with nothing shown, so the pill gets its
        // width and sits at the bottom.
        GeometryReader { proxy in
            ZStack {
                if let current = palette.current {
                    SpotlightPalette(palette: palette, current: current)
                        .transition(.opacity)
                }
                VStack {
                    if let copied = palette.copied {
                        CopiedPill(copied: copied, theme: palette.theme)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .id(copied.id)
                    }
                }
                .frame(width: SpotlightPalette.width(in: proxy.size))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Like macOS 26 Spotlight: a glass bar near the top that grows as results
/// come in, with the actions in a menu that opens by the selected row.
private struct SpotlightPalette: View {
    @Bindable var palette: CommandPalette
    let current: CommandPaletteConfig
    @FocusState private var focused: Bool

    private let rowHeight: CGFloat = 52
    private let fieldFont = Font.system(size: 24)

    static func width(in size: CGSize) -> CGFloat { min(700, size.width - 48) }

    var body: some View {
        let theme = palette.theme
        let results = palette.results
        let selected = palette.selected(in: results)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { palette.close() }
                VStack(spacing: 0) {
                    field(selected)
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 20)
                    chips(hasSelection: selected != nil)
                    if !results.isEmpty {
                        list(results, selected: selected, theme: theme)
                    } else if !palette.query.isEmpty {
                        Text("No Results")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.bottom, results.isEmpty ? 2 : 10)
                .frame(width: Self.width(in: proxy.size))
                .spotlightGlass(theme)
                .overlayPreferenceValue(SelectedRowBounds.self) { anchor in
                    if palette.showsActions, let anchor, let selected {
                        GeometryReader { panel in
                            actionsMenu(selected, theme: theme)
                                .padding(.trailing, 16)
                                .frame(width: panel.size.width, alignment: .trailing)
                                .offset(y: panel[anchor].maxY + 2)
                        }
                    }
                }
                .padding(.top, max(24, proxy.size.height * 0.13))
            }
        }
        // The Sidebar's label colors, which read better on glass than the
        // Ghostty foreground (Solarized's is a mid gray).
        .foregroundStyle(.primary)
        .environment(\.colorScheme, theme.colorScheme)
        .onAppear { focused = true; DispatchQueue.main.async { focused = true } }
    }

    // MARK: Field

    private func field(_ selected: PaletteItem?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                ghost(selected)
                TextField("", text: $palette.query, prompt: Text(current.placeholder).foregroundColor(.secondary))
                    .textFieldStyle(.plain)
                    .font(fieldFont)
                    .focused($focused)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    /// Spotlight's completion after the caret: the rest of the selected title.
    private func ghost(_ selected: PaletteItem?) -> some View {
        let query = palette.query
        return HStack(spacing: 0) {
            Text(query).hidden()
            if !query.isEmpty, let selected {
                if selected.title.lowercased().hasPrefix(query.lowercased()) {
                    Text(selected.title.dropFirst(query.count)).foregroundStyle(.secondary)
                } else {
                    Text(" – \(selected.title)").foregroundStyle(.secondary)
                }
            }
        }
        .font(fieldFont)
        .lineLimit(1)
        .allowsHitTesting(false)
    }

    // MARK: Chips and results

    /// The Source chips, on or off, and at the far end the way into the actions menu
    /// (whose first entry is Jump To).
    private func chips(hasSelection: Bool) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(palette.chips.enumerated()), id: \.element) { offset, source in
                let isOn = palette.selection.contains(source)
                Text(source.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.primary.opacity(isOn ? 0.16 : 0.06)))
                    .contentShape(Capsule())
                    .onTapGesture { palette.toggleChip(source) }
                    .help("⌘\(offset + 1)")
            }
            Spacer()
            if hasSelection {
                HStack(spacing: 5) {
                    Text("Actions")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.showsActions ? Color.primary : Color.secondary)
                    if let shortcut = palette.shortcut(for: .showActions) { KeyCap(text: shortcut) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    palette.actionIndex = 0
                    palette.showsActions.toggle()
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func list(_ results: [PaletteItem], selected: PaletteItem?, theme: PaletteTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { item in
                        row(item, isSelected: item.id == selected?.id, theme: theme)
                            .id(item.id)
                            .onTapGesture { palette.perform(.jumpTo, on: item) }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            // A half row shows there is more.
            .frame(height: (results.count > 7 ? 6.5 : CGFloat(results.count)) * rowHeight)
            .onChange(of: selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: PaletteItem, isSelected: Bool, theme: PaletteTheme) -> some View {
        HStack(spacing: 12) {
            PaletteIcon(source: .item(item), theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let status = item.status {
                Text(item.unread && status == .done ? "Done · Unread" : status.rawValue.capitalized)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.status(status, unread: item.unread) ?? .secondary)
            } else if item.isCurrent {
                Text("Current").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(isSelected ? 0.09 : 0)))
        .contentShape(Rectangle())
        .anchorPreference(key: SelectedRowBounds.self, value: .bounds) { isSelected ? $0 : nil }
    }

    // MARK: Actions

    private func actionsMenu(_ item: PaletteItem, theme: PaletteTheme) -> some View {
        let actions = palette.actions(for: item)
        return VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(Array(actions.enumerated()), id: \.element) { offset, action in
                HStack(spacing: 9) {
                    PaletteIcon(source: .action(action), theme: theme, size: 20)
                    Text(palette.title(of: action, for: item)).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 12)
                    if let shortcut = palette.shortcut(for: action) {
                        Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(offset == palette.actionIndex ? 0.1 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { palette.perform(action, on: item) }
            }
        }
        .padding(6)
        .frame(width: 290)
        // Nearly opaque: the rows under it would show through as blobs.
        .spotlightGlass(theme, cornerRadius: 16, tint: 0.9)
    }
}

/// Where the selected row is, so the actions menu can open under it.
private struct SelectedRowBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// App-icon sized: Agents and Windows as a little terminal with the
/// program's logo (and the Agent's Status as a badge), Sessions as a folder,
/// Session Paths as an empty folder or a branch, actions as a tile in a
/// theme color.
struct PaletteIcon: View {
    enum Source {
        case item(PaletteItem)
        case action(PaletteAction)
    }

    let source: Source
    let theme: PaletteTheme
    var size: CGFloat = 32

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        switch source {
        case .item(let item) where item.kind == .session:
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.78))
                .foregroundStyle(theme.cyan.gradient)
                .frame(width: size, height: size)
        case .item(let item) where item.kind == .sessionPath:
            Image(systemName: item.ref.isWorktree ? "arrow.triangle.branch" : "folder")
                .font(.system(size: size * (item.ref.isWorktree ? 0.6 : 0.72)))
                .foregroundStyle(theme.cyan)
                .frame(width: size, height: size)
        case .item(let item):
            tile.fill(theme.background)
                .overlay(tile.strokeBorder(Color.primary.opacity(0.14)))
                .overlay(Logo(name: item.logo ?? "terminal", size: size * 0.56))
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if let marker = AgentStatusMarker(status: item.status, unread: item.unread) {
                        AgentStatusIndicator(marker: marker, dotSize: size * 0.36)
                            .padding(marker == .working ? 2 : 0)
                            .background {
                                if marker == .working {
                                    RoundedRectangle(cornerRadius: 3).fill(theme.background)
                                }
                            }
                            .overlay {
                                if marker != .working {
                                    Circle().strokeBorder(theme.background, lineWidth: 2)
                                }
                            }
                            .offset(x: size * 0.1, y: size * 0.1)
                    }
                }
        case .action(let action):
            tile.fill(color(action).gradient)
                .overlay(Image(systemName: symbol(action))
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }

    private func color(_ action: PaletteAction) -> Color {
        switch action {
        case .copyPath: theme.cyan
        case .copyTarget: theme.magenta
        default: theme.blue
        }
    }

    private func symbol(_ action: PaletteAction) -> String {
        switch action {
        case .copyPath: "doc.on.doc.fill"
        case .copyTarget: "number"
        default: "arrow.up.forward"
        }
    }
}

private extension PaletteItem.Ref {
    var isWorktree: Bool {
        if case .sessionPath(let path) = self { return path.isWorktree }
        return false
    }
}

/// Springs in at the bottom after a Copy; its check is drawn on, then bounces
/// once.
private struct CopiedPill: View {
    let copied: PaletteCopy
    let theme: PaletteTheme
    @State private var showsCheck = false
    @State private var bounces = 0

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(theme.green)
                if showsCheck { check }
            }
            .frame(width: 22, height: 22)
            Text(copied.title)
                .font(.system(size: 13, weight: .semibold))
            Text(copied.value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 38)
        .spotlightGlass(theme, cornerRadius: 19, tint: 0.6)
        .foregroundStyle(.primary)
        .environment(\.colorScheme, theme.colorScheme)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.3)) { showsCheck = true }
            try? await Task.sleep(for: .milliseconds(380))
            bounces += 1
        }
    }

    @ViewBuilder private var check: some View {
        let image = Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: bounces)
        if #available(macOS 26.0, *) {
            image.transition(.symbolEffect(.drawOn))
        } else {
            image.transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

private extension View {
    /// Liquid Glass tinted with the Sidebar's chrome, or a material before macOS 26.
    @ViewBuilder
    func spotlightGlass(_ theme: PaletteTheme, cornerRadius: CGFloat = 26, tint: Double = 0.45) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular.tint(theme.chrome.opacity(tint)), in: shape)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        } else {
            self
                .background(shape.fill(theme.chrome.opacity(tint + 0.1)))
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
        }
    }
}
