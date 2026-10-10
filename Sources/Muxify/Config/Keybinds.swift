/// What a keybinding can do, with its default triggers.
protocol KeybindAction: CaseIterable, Hashable, RawRepresentable where RawValue == String {
    /// The defaults as the user spells them, so the template can show them.
    static var defaultSpelling: KeyValuePairs<Self, [String]> { get }
    static var defaultTriggers: [Self: [KeyTrigger]] { get }
}

extension KeybindAction {
    static func parse(_ spelling: KeyValuePairs<Self, [String]>) -> [Self: [KeyTrigger]] {
        Dictionary(uniqueKeysWithValues: spelling.map { action, spellings in (action, spellings.map { try! KeyTrigger($0) }) })
    }
}

/// What a Muxify keybind can do, anywhere in an App Window.
enum ConfigAction: String, KeybindAction {
    case newAppWindow = "new_app_window"
    case toggleSidebar = "toggle_sidebar"
    case toggleBrowser = "toggle_browser"
    case focusTerminal = "focus_terminal"
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

    static let defaultSpelling: KeyValuePairs<ConfigAction, [String]> = [
        .newAppWindow: ["cmd+n"],
        .toggleSidebar: ["cmd+s", "ctrl+cmd+s"],
        .toggleBrowser: ["cmd+b"],
        .focusTerminal: ["ctrl+backquote"],
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

    static let defaultTriggers = parse(defaultSpelling)
}

/// What a keybind does while a Command Palette is open, from
/// `keybindings.command_palette`. These win over the other keybinds then.
enum PaletteAction: String, KeybindAction {
    case jumpTo = "jump_to"
    case selectNext = "select_next"
    case selectPrev = "select_prev"
    case showActions = "show_actions"
    case copyPath = "copy_path"
    case copyTarget = "copy_target"

    static let defaultSpelling: KeyValuePairs<PaletteAction, [String]> = [
        .jumpTo: ["enter"],
        .selectNext: ["down", "ctrl+j"],
        .selectPrev: ["up", "ctrl+k"],
        .showActions: ["cmd+k"],
        .copyPath: ["cmd+c"],
        .copyTarget: ["cmd+shift+c"],
    ]

    static let defaultTriggers = parse(defaultSpelling)
}

/// Each action's triggers, in the order they were listed. No trigger belongs
/// to two actions.
struct KeybindSet<Action: KeybindAction>: Equatable {
    let triggers: [Action: [KeyTrigger]]

    static var defaults: Self { Self(triggers: Action.defaultTriggers) }

    func action(for trigger: KeyTrigger) -> Action? {
        triggers.first { $0.value.contains(trigger) }?.key
    }

    /// The trigger menus and tooltips show for `action`.
    func firstTrigger(for action: Action) -> KeyTrigger? {
        triggers[action]?.first
    }
}

/// Muxify's keybinds that work throughout an App Window.
typealias Keybinds = KeybindSet<ConfigAction>
/// The keybinds of an open Command Palette.
typealias PaletteKeybinds = KeybindSet<PaletteAction>

extension KeybindSet where Action == ConfigAction {
    /// Remapping/disabling New App Window must also remove Ghostty's fallback
    /// Cmd+N behavior, rather than leaving a second shortcut in the terminal.
    func suppressesDefaultAppWindowShortcut(_ trigger: KeyTrigger) -> Bool {
        trigger == Self.defaults.firstTrigger(for: .newAppWindow) && action(for: trigger) == nil
    }
}
