/// What a Muxify keybind can do.
enum ConfigAction: String, CaseIterable {
    case newAppWindow = "new_app_window"
    case toggleSidebar = "toggle_sidebar"
    case toggleBrowser = "toggle_browser"
    case selectWindow1 = "select_window_1"
    case selectWindow2 = "select_window_2"
    case selectWindow3 = "select_window_3"
    case selectWindow4 = "select_window_4"
    case selectWindow5 = "select_window_5"
    case selectWindow6 = "select_window_6"
    case selectWindow7 = "select_window_7"
    case selectWindow8 = "select_window_8"
    case selectWindow9 = "select_window_9"
    case selectNextWindow = "select_next_window"
    case selectPrevWindow = "select_prev_window"
}

/// Muxify's keybinds: each action's triggers, in the order they were listed.
/// No trigger belongs to two actions.
struct Keybinds: Equatable {
    let triggers: [ConfigAction: [KeyTrigger]]

    /// The defaults as the user spells them, so the template can show them.
    static let defaultSpelling: KeyValuePairs<ConfigAction, [String]> = [
        .newAppWindow: ["cmd+n"],
        .toggleSidebar: ["cmd+s", "ctrl+cmd+s"],
        .toggleBrowser: ["cmd+b"],
        .selectWindow1: ["cmd+1"],
        .selectWindow2: ["cmd+2"],
        .selectWindow3: ["cmd+3"],
        .selectWindow4: ["cmd+4"],
        .selectWindow5: ["cmd+5"],
        .selectWindow6: ["cmd+6"],
        .selectWindow7: ["cmd+7"],
        .selectWindow8: ["cmd+8"],
        .selectWindow9: ["cmd+9"],
        .selectNextWindow: [],
        .selectPrevWindow: [],
    ]

    static let defaults = Keybinds(triggers: Dictionary(uniqueKeysWithValues: defaultSpelling.map { action, spellings in
        (action, spellings.map { try! KeyTrigger($0) })
    }))

    func action(for trigger: KeyTrigger) -> ConfigAction? {
        triggers.first { $0.value.contains(trigger) }?.key
    }

    /// The trigger menus and tooltips show for `action`.
    func firstTrigger(for action: ConfigAction) -> KeyTrigger? {
        triggers[action]?.first
    }

    /// Remapping/disabling New App Window must also remove Ghostty's fallback
    /// Cmd+N behavior, rather than leaving a second shortcut in the terminal.
    func suppressesDefaultAppWindowShortcut(_ trigger: KeyTrigger) -> Bool {
        trigger == Self.defaults.firstTrigger(for: .newAppWindow) && action(for: trigger) == nil
    }
}
