import AppKit
import GhosttyKit

/// Things libghostty asks the host app to do that only the app can decide.
protocol GhosttyRuntimeDelegate: AnyObject {
    func ghosttyOpenURL(_ url: URL)
    func ghosttyNewTab()
    func ghosttyNewWindow()
    func ghosttyNewSplit(_ direction: ghostty_action_split_direction_e)
    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e)
    func ghosttyToggleSplitZoom()
    func ghosttyEqualizeSplits()
    func ghosttyGotoTab(_ tab: Int32)
    func ghosttySurfaceClosed(_ view: TerminalSurfaceView)
    func ghosttyThemeChanged(_ theme: TerminalTheme)
    func ghosttyReloadConfig()
}

/// The colors of the active Ghostty theme, for tinting Muxify's own chrome.
struct TerminalTheme: Equatable {
    let background: NSColor
    let foreground: NSColor

    init?(config: ghostty_config_t) {
        guard let background = Self.color(config, "background"),
              let foreground = Self.color(config, "foreground") else { return nil }
        self.background = background
        self.foreground = foreground
    }

    var isDark: Bool {
        guard let rgb = background.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
    }

    /// Header and sidebar: the terminal background shaded slightly toward the
    /// foreground, so they read as chrome around the terminal.
    var chrome: NSColor {
        background.blended(withFraction: 0.06, of: foreground) ?? background
    }

    var separator: NSColor {
        foreground.withAlphaComponent(isDark ? 0.18 : 0.14)
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var color = ghostty_config_color_s()
        let found = key.withCString { ghostty_config_get(config, &color, $0, UInt(key.utf8.count)) }
        guard found else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}

/// Owns the single `ghostty_app_t` and bridges libghostty's C callbacks.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var theme: TerminalTheme?
    weak var delegate: GhosttyRuntimeDelegate?

    private init() {}

    /// Must run before any surface is created.
    func start(ghosttyConfigFile: String?) {
        guard app == nil else { return }
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("muxify: ghostty_init failed")
            return
        }
        config = Self.loadConfig(ghosttyConfigFile: ghosttyConfigFile)

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.shared.handle(action: action, target: target)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, string: string, state: state, request: request)
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, _ in
                guard let view = TerminalSurfaceView.from(userdata) else { return }
                DispatchQueue.main.async { view.delegate?.ghosttySurfaceClosed(view) }
            }
        )
        app = ghostty_app_new(&runtime, config)
        if app == nil { NSLog("muxify: ghostty_app_new failed") }
        // Resolve a light:/dark: theme pair right away so the chrome has the
        // right colors before the first terminal exists. libghostty only
        // re-applies the config when the scheme *changes* (it starts as
        // light), so apply it once explicitly to get a CONFIG_CHANGE.
        setColorScheme(dark: NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if let app, let config { ghostty_app_update_config(app, config) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
        }
        center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// Re-reads the config files. libghostty answers with CONFIG_CHANGE,
    /// which carries the resolved theme colors.
    func reloadConfig(ghosttyConfigFile: String?) {
        guard let app, let fresh = Self.loadConfig(ghosttyConfigFile: ghosttyConfigFile) else { return }
        ghostty_app_update_config(app, fresh)
        // Free the old config only after libghostty has switched to the new one.
        if let old = config { ghostty_config_free(old) }
        config = fresh
    }

    /// Re-applies the current config, e.g. after the light/dark appearance
    /// changed and a theme pair needs to resolve to the other theme.
    private func softReload(target: ghostty_target_s) {
        guard let app, let config else { return }
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            ghostty_surface_update_config(surface, config)
        } else {
            ghostty_app_update_config(app, config)
        }
    }

    /// Only from CONFIG_CHANGE: a freshly loaded config has the built-in
    /// default colors until libghostty applies the light/dark state to it.
    private func updateTheme(from config: ghostty_config_t) {
        guard let theme = TerminalTheme(config: config), theme != self.theme else { return }
        self.theme = theme
        delegate?.ghosttyThemeChanged(theme)
    }

    /// The user's normal Ghostty config (~/.config/ghostty/config etc.), so
    /// fonts, themes and keybinds match their standalone Ghostty, with the
    /// file the Config names on top, as `ghostty --config-file=` does.
    private static func loadConfig(ghosttyConfigFile: String?) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        if let ghosttyConfigFile { ghostty_config_load_file(config, ghosttyConfigFile) }
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            if let message = diagnostic.message { NSLog("muxify: ghostty config: \(String(cString: message))") }
        }
        return config
    }

    // MARK: - Actions

    private func handle(action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        let surfaceView: TerminalSurfaceView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? TerminalSurfaceView.from(ghostty_surface_userdata(target.target.surface))
            : nil
        // A retired/orphaned surface must never fall back to a different
        // window's Environment. Only app-targeted actions use focused routing.
        let actionDelegate = target.tag == GHOSTTY_TARGET_SURFACE ? surfaceView?.delegate : delegate

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        case GHOSTTY_ACTION_OPEN_URL:
            let raw = action.action.open_url
            guard let ptr = raw.url else { return false }
            let data = Data(bytes: ptr, count: Int(raw.len))
            let string = String(decoding: data, as: UTF8.self)
            guard let url = URL(string: string) ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
                return false
            }
            actionDelegate?.ghosttyOpenURL(url)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            surfaceView?.setCursorShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_NEW_TAB:
            actionDelegate?.ghosttyNewTab()
        case GHOSTTY_ACTION_NEW_WINDOW:
            actionDelegate?.ghosttyNewWindow()
        case GHOSTTY_ACTION_NEW_SPLIT:
            actionDelegate?.ghosttyNewSplit(action.action.new_split)
        case GHOSTTY_ACTION_GOTO_SPLIT:
            actionDelegate?.ghosttyGotoSplit(action.action.goto_split)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            actionDelegate?.ghosttyToggleSplitZoom()
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            actionDelegate?.ghosttyEqualizeSplits()
        case GHOSTTY_ACTION_GOTO_TAB:
            actionDelegate?.ghosttyGotoTab(action.action.goto_tab.rawValue)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // tmux client exited (detach, server gone): skip libghostty's
            // "press any key" screen and let the app show its own placeholder.
            // Deferred because freeing a surface inside its own callback is unsafe.
            guard let surfaceView else { return false }
            DispatchQueue.main.async { surfaceView.delegate?.ghosttySurfaceClosed(surfaceView) }
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            if action.action.reload_config.soft {
                softReload(target: target)
            } else {
                actionDelegate?.ghosttyReloadConfig()
            }
        case GHOSTTY_ACTION_RING_BELL:
            // tmux rings the bell for activity in other Windows (monitor-activity),
            // which is constant with agents running, so never beep. Like
            // Ghostty's default, only ask for attention while in the background.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Only valid during this callback, so read the colors right away.
            if let changed = action.action.config_change.config { updateTheme(from: changed) }
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_SCROLLBAR:
            // Sidebar labels come from tmux; nothing to do for these in the POC.
            return true
        default:
            return false
        }
        return true
    }

    // MARK: - Clipboard

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface = TerminalSurfaceView.from(userdata)?.surface else { return false }
        let string = NSPasteboard.general.string(forType: .string) ?? ""
        string.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface = TerminalSurfaceView.from(userdata)?.surface else { return }
        // Pastes the user initiated are confirmed; programs reading the
        // clipboard through OSC 52 get nothing.
        let allowed = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        let value = allowed ? (string.map { String(cString: $0) } ?? "") : ""
        value.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
    }

    private static func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, count > 0 else { return }
        var text: String?
        for i in 0..<count {
            let item = content[i]
            guard let data = item.data else { continue }
            let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
            if mime.hasPrefix("text/plain") || text == nil {
                text = String(cString: data)
            }
        }
        guard let text else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
