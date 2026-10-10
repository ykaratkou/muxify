import Foundation
import Yams

/// A Config value that could not apply, or the syntax error that stopped the
/// whole file from applying.
struct ConfigProblem: Equatable, CustomStringConvertible {
    let path: String
    let line: Int
    let message: String

    var description: String { "\(path):\(line): \(message)" }
}

/// A Config file that is not valid YAML. Nothing in it applies.
struct ConfigSyntaxError: Error, Equatable {
    let problem: ConfigProblem
}

/// The Config: how Muxify itself behaves, read from a YAML file.
struct Config: Equatable {
    var keybinds = Keybinds.defaults
    /// The keybinds of an open Command Palette (`keybindings.command_palette`).
    var paletteKeybinds = PaletteKeybinds.defaults
    /// In Config order (ADR 0009).
    var commandPalettes = [CommandPaletteConfig.goTo]
    /// Where the Session Paths come from, in Config order.
    var sessionPaths: [SessionPathRoot] = []
    /// Height of the app's header in points; at least 24 to fit its buttons.
    var headerHeight: Double = 30
    /// Typography of the Sidebar's Sessions and Agents, not the terminal.
    var sidebarTypography = SidebarTypography()
    /// The Ghostty config file the terminal loads on top of Ghostty's
    /// default files, as an absolute path.
    var ghosttyConfigFile: String?
    /// In file order; Local is always available and is never declared here.
    var remoteEnvironments: [RemoteEnvironment] = []
    var problems: [ConfigProblem] = []

    static var defaultPath: String {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(NSHomeDirectory())/.config"
        return "\(xdg)/muxify/config.yaml"
    }

    /// Reads the Config at `path`. A missing file gives the defaults. A value
    /// that cannot apply is skipped and recorded in `problems`; a syntax error
    /// fails the whole read. A Remote Environment's Config skips the sections
    /// about the app itself (ADR 0010).
    static func load(path: String, isRemote: Bool = false,
                     fontFamilies: @escaping () -> [String] = { SidebarTypography.fontFamilies },
                     read: (String) -> String?) -> Result<Config, ConfigSyntaxError> {
        guard let text = read(path) else { return .success(Config()) }
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            return .failure(ConfigSyntaxError(path: path, error))
        }
        guard let root else { return .success(Config()) }
        return withoutActuallyEscaping(read) { read in
            var reader = ConfigReader(path: path, isRemote: isRemote, read: read, fontFamilies: fontFamilies)
            reader.readSections(root)
            return .success(reader.config)
        }
    }

    /// What Open Config writes into a new Config file.
    static var template: String {
        func spell<Action: KeybindAction>(_ defaults: KeyValuePairs<Action, [String]>, indent: String) -> String {
            defaults.map { action, spellings in
                "#\(indent)\(action.rawValue): \(spellings.count == 1 ? spellings[0] : "[\(spellings.joined(separator: ", "))]")"
            }.joined(separator: "\n")
        }
        return """
        # Muxify Config. Muxify reloads it when it changes.
        #
        # ghostty:
        #   # The Ghostty config the terminal loads after Ghostty's default
        #   # files. ~/ is the home directory; a relative path starts at the
        #   # directory of this file.
        #   config_file: ~/.config/ghostty/config
        #
        # ui:
        #   # Header height in points (minimum 24). Changes apply live.
        #   header_height: 30
        #   sidebar:
        #     # Positive base size in points; other text scales proportionally.
        #     # Changes apply live. Invalid values use the defaults below.
        #     font_size: 12
        #     # system, or an installed macOS font family (case-insensitive).
        #     font_family: system
        #
        # sessions:
        #   # Folders the Command Palette offers as Sessions. depth 0 (the
        #   # default) is the folder itself; 1 lists its subfolders, 2 goes two
        #   # levels deep. Hidden folders are skipped, and so are folders this
        #   # machine doesn't have. Git worktrees of these folders are listed too.
        #   paths:
        #     - path: ~/projects
        #       depth: 1
        #     - path: ~/.dotfiles
        #
        # command_palettes:
        #   # A palette opens with its sources selected: sessions (with the
        #   # folders above), windows or agents. Cmd+1–Cmd+3 select the others
        #   # too. Without this section there is one, Go to…, on cmd+shift+p
        #   # with every source; [] removes it.
        #   - name: Sessions
        #     keybinding: cmd+p
        #     sources: [sessions, windows]
        #   - name: Agents
        #     keybinding: cmd+shift+o
        #     sources: [agents]
        #
        # remote_environments:
        #   # A Remote Environment's App Window uses that machine's own Config
        #   # when it has one, without its ghostty and remote_environments.
        #   - name: Macbook Home
        #     host: macbook-home.example.ts.net
        #     username: your-user
        #     # port: 22
        #     # identity_file: ~/.ssh/id_ed25519
        #     # forward_agent: false  # Agent forwarding is enabled by default.
        #
        # keybindings:
        #   # An action maps to one trigger or a list of them, spelled as in
        #   # Ghostty. Naming an action replaces its defaults, and [] leaves it
        #   # with no keybinding. A trigger listed here is taken from the
        #   # defaults of other actions.
        #   # Keybindings work throughout Muxify, including in the Browser.
        #   # focus_terminal uses Ctrl+backquote, leaving Cmd+backquote for
        #   # macOS App Window switching unless you explicitly bind it here.
        #   # select_window_1 through select_window_9 pick the first through
        #   # ninth Windows in the current Session, not their tmux indices.
        #   # select_next_window and select_prev_window wrap within the Session
        #   # and have no keybindings until you assign them.
        #   # The defaults:
        \(spell(ConfigAction.defaultSpelling, indent: "   "))
        #   # While a Command Palette is open, these act instead:
        #   command_palette:
        \(spell(PaletteAction.defaultSpelling, indent: "     "))

        """
    }
}

/// What Muxify runs with: the last Config that read without a syntax error,
/// and the problems of the latest read. A half-typed edit shows its syntax
/// error but does not reset the keybinds in use.
struct LoadedConfig: Equatable {
    private(set) var config = Config()
    private(set) var problems: [ConfigProblem] = []

    mutating func update(with result: Result<Config, ConfigSyntaxError>) {
        switch result {
        case .success(let config):
            self.config = config
            problems = config.problems
        case .failure(let error):
            problems = [error.problem]
        }
    }
}

private extension ConfigSyntaxError {
    init(path: String, _ error: Error) {
        switch error as? YamlError {
        case let .scanner(context, message, mark, _), let .parser(context, message, mark, _), let .composer(context, message, mark, _):
            let text = [context?.text, message].compactMap { $0 }.joined(separator: ": ")
            problem = ConfigProblem(path: path, line: mark.line, message: text)
        case let .duplicatedKeysInMapping(duplicates, context):
            problem = ConfigProblem(path: path, line: context.mark.line, message: "duplicate key \(duplicates.joined(separator: ", "))")
        default:
            problem = ConfigProblem(path: path, line: 1, message: "\(error)")
        }
    }
}

/// Turns the YAML nodes of one Config file into a Config, skipping what
/// cannot apply.
private struct ConfigReader {
    let path: String
    let isRemote: Bool
    let read: (String) -> String?
    let fontFamilies: () -> [String]
    var config = Config()

    /// Who a trigger can be bound to anywhere in an App Window.
    private enum Claimant: Hashable {
        case action(ConfigAction)
        case palette(String)

        var description: String {
            switch self {
            case .action(let action): action.rawValue
            case .palette(let name): "the \(name) Command Palette"
            }
        }
    }

    private struct Claim<Owner> {
        let owner: Owner
        let trigger: KeyTrigger
        let node: Node
    }

    /// The `keybindings` actions and Command Palettes, whose triggers are
    /// settled once every section is read.
    private var namedActions: [ConfigAction] = []
    private var palettes: [CommandPaletteConfig]?
    private var claims: [Claim<Claimant>] = []

    init(path: String, isRemote: Bool, read: @escaping (String) -> String?, fontFamilies: @escaping () -> [String]) {
        self.path = path
        self.isRemote = isRemote
        self.read = read
        self.fontFamilies = fontFamilies
    }

    static let sections: [String: (inout ConfigReader, Node) -> Void] = [
        "ghostty": { $0.readGhostty($1) },
        "ui": { $0.readUI($1) },
        "keybindings": { $0.readKeybindings($1) },
        "command_palettes": { $0.readCommandPalettes($1) },
        "sessions": { $0.readSessions($1) },
        "remote_environments": { $0.readRemoteEnvironments($1) },
    ]

    /// About the app on this Mac, not the machine the Config is on.
    static let appSections: Set<String> = ["ghostty", "remote_environments"]

    mutating func readSections(_ root: Node) {
        for (name, key, value) in entries(of: root, "the Config") {
            if isRemote, Self.appSections.contains(name) { continue }
            guard let section = Self.sections[name] else {
                problem(at: key, "unknown section \"\(name)\"")
                continue
            }
            section(&self, value)
        }
        resolveKeybindings()
        // In file order, although conflicts are found after every section.
        config.problems = config.problems.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
    }

    mutating func readGhostty(_ node: Node) {
        for (name, key, value) in entries(of: node, "ghostty") {
            switch name {
            case "config_file":
                guard let path = string(value) else {
                    problem(at: value, "ghostty.config_file: expected a path")
                    continue
                }
                let file = ConfigFileSet.resolve(path, relativeTo: (self.path as NSString).deletingLastPathComponent)
                // Kept although missing, so the watcher sees the file appear.
                config.ghosttyConfigFile = file
                if read(file) == nil { problem(at: value, "ghostty.config_file \(file): not found") }
            default:
                problem(at: key, "unknown key \"ghostty.\(name)\"")
            }
        }
    }

    mutating func readRemoteEnvironments(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "remote_environments: expected a list")
            return
        }
        var names: Set<String> = ["Local"]
        for item in sequence {
            let problemCount = config.problems.count
            let fields = entries(of: item, "a Remote Environment")
            var values: [String: Node] = [:]
            for (name, key, value) in fields {
                guard ["name", "host", "username", "port", "identity_file", "forward_agent"].contains(name) else {
                    problem(at: key, "unknown Remote Environment key \"\(name)\"")
                    continue
                }
                values[name] = value
            }
            func required(_ key: String) -> String? {
                values[key].flatMap(string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = required("name")
            let host = required("host")
            let username = required("username")
            for (key, value) in [("name", name), ("host", host), ("username", username)] {
                if value?.isEmpty != false {
                    problem(at: values[key] ?? item, "Remote Environment \(key): expected a nonempty string")
                }
            }
            if let name, name.rangeOfCharacter(from: .controlCharacters) != nil {
                problem(at: values["name"] ?? item, "Remote Environment name: control characters are not allowed")
            }
            for (key, value) in [("host", host), ("username", username)] {
                if let value, !value.isEmpty,
                   value.hasPrefix("-") || value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil {
                    problem(at: values[key] ?? item, "Remote Environment \(key): expected a host or username without whitespace or a leading '-'")
                }
            }
            var port: Int?
            if let value = values["port"], value.null == nil {
                if let number = value.int, (1...65535).contains(number) {
                    port = number
                } else {
                    problem(at: value, "Remote Environment port: expected an integer from 1 to 65535")
                }
            }
            var identityFile: String?
            if let value = values["identity_file"], value.null == nil {
                if let path = string(value), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   path.rangeOfCharacter(from: .controlCharacters) == nil {
                    identityFile = ConfigFileSet.resolve(path, relativeTo: (self.path as NSString).deletingLastPathComponent)
                } else {
                    problem(at: value, "Remote Environment identity_file: expected a local path")
                }
            }
            var forwardAgent = true
            if let value = values["forward_agent"], value.null == nil {
                if let enabled = value.bool {
                    forwardAgent = enabled
                } else {
                    problem(at: value, "Remote Environment forward_agent: expected true or false")
                }
            }
            if let name, names.contains(name) {
                problem(at: values["name"] ?? item, "Remote Environment name \"\(name)\" is already used (Local is reserved)")
            }
            guard config.problems.count == problemCount, let name, let host, let username else { continue }
            names.insert(name)
            config.remoteEnvironments.append(RemoteEnvironment(
                name: name, host: host, username: username, port: port, identityFile: identityFile,
                forwardAgent: forwardAgent
            ))
        }
    }

    mutating func readUI(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui") {
            switch name {
            case "header_height":
                guard let height = value.float, height.isFinite, height >= 24 else {
                    problem(at: value, "ui.header_height: expected a finite number of at least 24 points")
                    continue
                }
                config.headerHeight = height
            case "sidebar":
                readSidebar(value)
            default:
                problem(at: key, "unknown key \"ui.\(name)\"")
            }
        }
    }

    mutating func readSidebar(_ node: Node) {
        for (name, key, value) in entries(of: node, "ui.sidebar") {
            switch name {
            case "font_size":
                guard value.tag == Tag(.int) || value.tag == Tag(.float),
                      let size = value.float, size.isFinite, size > 0 else {
                    problem(at: value, "ui.sidebar.font_size: expected a finite number greater than zero points")
                    continue
                }
                config.sidebarTypography.fontSize = size
            case "font_family":
                guard value.tag == Tag(.str), let name = value.string,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.rangeOfCharacter(from: .controlCharacters) == nil else {
                    problem(at: value, "ui.sidebar.font_family: expected a nonempty font family name")
                    continue
                }
                guard let family = SidebarTypography.canonicalFamily(name, families: fontFamilies) else {
                    problem(at: value, "ui.sidebar.font_family: font family \"\(name.trimmingCharacters(in: .whitespacesAndNewlines))\" is not installed")
                    continue
                }
                config.sidebarTypography.fontFamily = family
            default:
                problem(at: key, "unknown key \"ui.sidebar.\(name)\"")
            }
        }
    }

    mutating func readKeybindings(_ node: Node) {
        for (name, key, value) in entries(of: node, "keybindings") {
            if name == "command_palette" {
                readPaletteKeybindings(value)
                continue
            }
            guard let action = ConfigAction(rawValue: name) else {
                problem(at: key, "unknown action \"\(name)\"")
                continue
            }
            guard let listed = triggers(in: value, of: name) else { continue }
            namedActions.append(action)
            claims += listed.map { Claim(owner: .action(action), trigger: $0.trigger, node: $0.node) }
        }
    }

    /// Only while a palette is open, so they never conflict with the others.
    mutating func readPaletteKeybindings(_ node: Node) {
        var named: [PaletteAction] = []
        var claims: [Claim<PaletteAction>] = []
        for (name, key, value) in entries(of: node, "keybindings.command_palette") {
            guard let action = PaletteAction(rawValue: name) else {
                problem(at: key, "unknown Command Palette action \"\(name)\"")
                continue
            }
            guard let listed = triggers(in: value, of: name) else { continue }
            named.append(action)
            claims += listed.map { Claim(owner: action, trigger: $0.trigger, node: $0.node) }
        }
        let kept = resolve(claims, describe: \.rawValue)
        config.paletteKeybinds = overlay(named: named, kept: kept, claimed: Set(kept.values.joined()))
    }

    mutating func readCommandPalettes(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "command_palettes: expected a list")
            return
        }
        var palettes: [CommandPaletteConfig] = []
        for item in sequence {
            let problemCount = config.problems.count
            var values: [String: Node] = [:]
            for (name, key, value) in entries(of: item, "a Command Palette") {
                guard ["name", "keybinding", "sources"].contains(name) else {
                    problem(at: key, "unknown Command Palette key \"\(name)\"")
                    continue
                }
                values[name] = value
            }
            let name = values["name"].flatMap(string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if name?.isEmpty != false || name?.rangeOfCharacter(from: .controlCharacters) != nil {
                problem(at: values["name"] ?? item, "Command Palette name: expected a nonempty string")
            } else if let name, palettes.contains(where: { $0.name == name }) {
                problem(at: values["name"] ?? item, "Command Palette name \"\(name)\" is already used")
            }
            var sources: [PaletteSource] = []
            for value in values["sources"].map({ $0.sequence ?? [$0] }) ?? [] {
                guard let source = string(value).flatMap(PaletteSource.init(rawValue:)) else {
                    problem(at: value, "Command Palette sources: expected sessions, windows or agents")
                    continue
                }
                if !sources.contains(source) { sources.append(source) }
            }
            if sources.isEmpty, config.problems.count == problemCount {
                problem(at: values["sources"] ?? item, "Command Palette sources: expected a list of sessions, windows or agents")
            }
            guard config.problems.count == problemCount, let name else { continue }
            palettes.append(CommandPaletteConfig(name: name, triggers: [], sources: sources))
            // A bad trigger is skipped; the palette still applies.
            if let value = values["keybinding"], value.null == nil, let listed = triggers(in: value, of: "Command Palette keybinding") {
                claims += listed.map { Claim(owner: .palette(name), trigger: $0.trigger, node: $0.node) }
            }
        }
        self.palettes = palettes
    }

    mutating func readSessions(_ node: Node) {
        for (name, key, value) in entries(of: node, "sessions") {
            switch name {
            case "paths":
                readSessionPaths(value)
            default:
                problem(at: key, "unknown key \"sessions.\(name)\"")
            }
        }
    }

    /// A folder missing on this machine is not a problem: the Config may be
    /// shared by several Macs.
    mutating func readSessionPaths(_ node: Node) {
        guard let sequence = node.sequence else {
            problem(at: node, "sessions.paths: expected a list")
            return
        }
        for item in sequence {
            let problemCount = config.problems.count
            var values: [String: Node] = [:]
            for (name, key, value) in entries(of: item, "a Session Path") {
                guard ["path", "depth"].contains(name) else {
                    problem(at: key, "unknown Session Path key \"\(name)\"")
                    continue
                }
                values[name] = value
            }
            let path = values["path"].flatMap(string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isValid = path.map {
                ($0 == "~" || $0.hasPrefix("~/") || $0.hasPrefix("/")) && $0.rangeOfCharacter(from: .controlCharacters) == nil
            } ?? false
            if !isValid {
                problem(at: values["path"] ?? item, "Session Path path: expected an absolute path or one starting with ~/")
            }
            var depth = 0
            if let value = values["depth"], value.null == nil {
                if value.tag == Tag(.int), let number = value.int, number >= 0 {
                    depth = number
                } else {
                    problem(at: value, "Session Path depth: expected a whole number of 0 or more")
                }
            }
            guard config.problems.count == problemCount, let path else { continue }
            config.sessionPaths.append(SessionPathRoot(path: path, depth: depth))
        }
    }

    /// The overlay rules across `keybindings` and `command_palettes`. An
    /// action the user named has only the triggers listed for it; so does a
    /// palette the Config defines. An action not named, and the default
    /// palette, keep their defaults minus any trigger listed for another.
    private mutating func resolveKeybindings() {
        let kept = resolve(claims, describe: \.description)
        let claimed = Set(kept.values.joined())
        var actions: [ConfigAction: [KeyTrigger]] = [:]
        for case let (.action(action), triggers) in kept { actions[action] = triggers }
        config.keybinds = overlay(named: namedActions, kept: actions, claimed: claimed)
        if let palettes {
            config.commandPalettes = palettes.map { palette in
                var palette = palette
                palette.triggers = kept[.palette(palette.name)] ?? []
                return palette
            }
        } else {
            config.commandPalettes = [CommandPaletteConfig.goTo].map { palette in
                var palette = palette
                palette.triggers.removeAll(where: claimed.contains)
                return palette
            }
        }
    }

    /// A trigger listed twice stays with the first.
    private mutating func resolve<Owner: Hashable>(_ claims: [Claim<Owner>], describe: (Owner) -> String) -> [Owner: [KeyTrigger]] {
        var owners: [KeyTrigger: Owner] = [:]
        var kept: [Owner: [KeyTrigger]] = [:]
        for claim in claims {
            switch owners[claim.trigger] {
            case nil:
                owners[claim.trigger] = claim.owner
                kept[claim.owner, default: []].append(claim.trigger)
            case claim.owner?:
                continue
            case let owner?:
                problem(at: claim.node, "\(claim.node.string ?? "") is already bound to \(describe(owner))")
            }
        }
        return kept
    }

    private func overlay<Action: KeybindAction>(named: [Action], kept: [Action: [KeyTrigger]], claimed: Set<KeyTrigger>) -> KeybindSet<Action> {
        var triggers: [Action: [KeyTrigger]] = [:]
        for action in Action.allCases {
            triggers[action] = named.contains(action)
                ? kept[action] ?? []
                : Action.defaultTriggers[action, default: []].filter { !claimed.contains($0) }
        }
        return KeybindSet(triggers: triggers)
    }

    /// One trigger or a list of them. A bad item of a list is skipped; a bad
    /// single value skips the setting, so it keeps its defaults.
    private mutating func triggers(in node: Node, of setting: String) -> [(trigger: KeyTrigger, node: Node)]? {
        if let sequence = node.sequence {
            return sequence.compactMap { trigger(in: $0, of: setting) }
        }
        return trigger(in: node, of: setting).map { [$0] }
    }

    private mutating func trigger(in node: Node, of setting: String) -> (trigger: KeyTrigger, node: Node)? {
        guard let spelling = string(node) else {
            problem(at: node, "\(setting): expected a trigger or a list of triggers")
            return nil
        }
        do {
            return (try KeyTrigger(spelling), node)
        } catch {
            problem(at: node, "\(error)")
            return nil
        }
    }

    private mutating func entries(of node: Node, _ place: String) -> [(name: String, key: Node, value: Node)] {
        guard let mapping = node.mapping else {
            problem(at: node, "\(place): expected a mapping")
            return []
        }
        return mapping.map { ($0.key.string ?? "", $0.key, $0.value) }
    }

    /// A scalar other than null (empty, `~` or `null`).
    private func string(_ node: Node) -> String? {
        guard let scalar = node.scalar, node.null == nil else { return nil }
        return scalar.string
    }

    private mutating func problem(at node: Node, _ message: String) {
        config.problems.append(ConfigProblem(path: path, line: node.mark?.line ?? 1, message: message))
    }
}
