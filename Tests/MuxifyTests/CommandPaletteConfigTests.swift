import XCTest

final class CommandPaletteConfigTests: XCTestCase {
    private let root = "/cfg/muxify/config.yaml"

    private func load(_ text: String, isRemote: Bool = false) throws -> Config {
        try Config.load(path: root, isRemote: isRemote, fontFamilies: { [] }) { $0 == self.root ? text : nil }.get()
    }

    private func trigger(_ string: String) -> KeyTrigger {
        try! KeyTrigger(string)
    }

    func testDefaultsAreOneGoToPaletteAndThePaletteKeys() throws {
        let config = try load("")
        XCTAssertEqual(config.commandPalettes, [CommandPaletteConfig(
            name: "Go to…", triggers: [trigger("cmd+shift+p")], sources: [.agents, .sessions, .windows]
        )])
        XCTAssertEqual(config.commandPalettes[0].placeholder, "Go to…")
        let keys = config.paletteKeybinds
        XCTAssertEqual(keys.action(for: trigger("enter")), .jumpTo)
        XCTAssertEqual(keys.action(for: trigger("down")), .selectNext)
        XCTAssertEqual(keys.action(for: trigger("ctrl+j")), .selectNext)
        XCTAssertEqual(keys.action(for: trigger("up")), .selectPrev)
        XCTAssertEqual(keys.action(for: trigger("ctrl+k")), .selectPrev)
        XCTAssertEqual(keys.action(for: trigger("cmd+k")), .showActions)
        XCTAssertEqual(keys.action(for: trigger("cmd+c")), .copyPath)
        XCTAssertEqual(keys.action(for: trigger("cmd+shift+c")), .copyTarget)
        XCTAssertEqual(config.sessionPaths, [])
        XCTAssertEqual(config.problems, [])
    }

    func testTheExampleConfig() throws {
        let config = try load("""
        keybindings:
          command_palette:
            copy_path: cmd+c
            jump_to: enter

        sessions:
          paths:
            - path: ~/projects
              depth: 1
            - path: ~/.dotfiles

        command_palettes:
          - name: "Sessions"
            keybinding: "cmd+p"
            sources: [sessions, windows]
          - name: "Agents"
            keybinding: "cmd+shift+o"
            sources: [agents]
        """)
        XCTAssertEqual(config.problems, [])
        XCTAssertEqual(config.sessionPaths, [SessionPathRoot(path: "~/projects", depth: 1), SessionPathRoot(path: "~/.dotfiles", depth: 0)])
        XCTAssertEqual(config.commandPalettes, [
            CommandPaletteConfig(name: "Sessions", triggers: [trigger("cmd+p")], sources: [.sessions, .windows]),
            CommandPaletteConfig(name: "Agents", triggers: [trigger("cmd+shift+o")], sources: [.agents]),
        ])
        XCTAssertEqual(config.commandPalettes[0].placeholder, "Search Sessions")
        XCTAssertEqual(config.paletteKeybinds, .defaults)
        XCTAssertEqual(config.keybinds, .defaults)
    }

    func testAnEmptyListRemovesEveryPalette() throws {
        let config = try load("command_palettes: []")
        XCTAssertEqual(config.commandPalettes, [])
        XCTAssertEqual(config.problems, [])
    }

    func testAPaletteKeybindingIsTakenFromTheDefaultsOfAnAction() throws {
        let config = try load("""
        command_palettes:
          - name: Browse
            keybinding: [cmd+b, ctrl+cmd+b]
            sources: windows
        """)
        XCTAssertEqual(config.commandPalettes.first?.triggers, [trigger("cmd+b"), trigger("ctrl+cmd+b")])
        XCTAssertEqual(config.commandPalettes.first?.sources, [.windows])
        XCTAssertNil(config.keybinds.firstTrigger(for: .toggleBrowser))
        XCTAssertEqual(config.problems, [])
    }

    func testAKeybindingClaimedFirstStaysWhereItWas() throws {
        let actionFirst = try load("""
        keybindings:
          toggle_browser: cmd+p
        command_palettes:
          - name: Sessions
            keybinding: [cmd+p, cmd+shift+p]
            sources: [sessions]
        """)
        XCTAssertEqual(actionFirst.keybinds.action(for: trigger("cmd+p")), .toggleBrowser)
        XCTAssertEqual(actionFirst.commandPalettes.first?.triggers, [trigger("cmd+shift+p")])
        XCTAssertEqual(actionFirst.problems, [
            ConfigProblem(path: root, line: 5, message: "cmd+p is already bound to toggle_browser"),
        ])

        let paletteFirst = try load("""
        command_palettes:
          - name: Sessions
            keybinding: cmd+p
            sources: [sessions]
          - name: Agents
            keybinding: cmd+p
            sources: [agents]
        keybindings:
          toggle_browser: [cmd+p, cmd+e]
        """)
        XCTAssertEqual(paletteFirst.commandPalettes.map(\.triggers), [[trigger("cmd+p")], []])
        XCTAssertEqual(paletteFirst.keybinds.triggers[.toggleBrowser], [trigger("cmd+e")])
        XCTAssertEqual(paletteFirst.problems, [
            ConfigProblem(path: root, line: 6, message: "cmd+p is already bound to the Sessions Command Palette"),
            ConfigProblem(path: root, line: 9, message: "cmd+p is already bound to the Sessions Command Palette"),
        ])
    }

    func testAnActionCanTakeTheDefaultPalettesKeybinding() throws {
        let config = try load("keybindings:\n  toggle_sidebar: cmd+shift+p")
        XCTAssertEqual(config.commandPalettes.first?.name, "Go to…")
        XCTAssertEqual(config.commandPalettes.first?.triggers, [])
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+p")), .toggleSidebar)
        XCTAssertEqual(config.problems, [])
    }

    func testPalettesThatCannotApplyAreSkipped() throws {
        let config = try load("""
        command_palettes:
          - name: Sessions
            sources: [sessions]
          - name: Sessions
            sources: [windows]
          - name: Files
            sources: [files]
          - name: Nothing
          - sources: [agents]
          - name: Odd
            sources: [agents]
            color: red
          - name: Agents
            keybinding: [hyper+a, cmd+shift+o]
            sources: [agents, agents]
        """)
        XCTAssertEqual(config.commandPalettes, [
            CommandPaletteConfig(name: "Sessions", triggers: [], sources: [.sessions]),
            CommandPaletteConfig(name: "Agents", triggers: [trigger("cmd+shift+o")], sources: [.agents]),
        ])
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 4, message: "Command Palette name \"Sessions\" is already used"),
            ConfigProblem(path: root, line: 7, message: "Command Palette sources: expected sessions, windows or agents"),
            ConfigProblem(path: root, line: 8, message: "Command Palette sources: expected a list of sessions, windows or agents"),
            ConfigProblem(path: root, line: 9, message: "Command Palette name: expected a nonempty string"),
            ConfigProblem(path: root, line: 12, message: "unknown Command Palette key \"color\""),
            ConfigProblem(path: root, line: 14, message: "bad trigger \"hyper+a\": unknown modifier \"hyper\""),
        ])
        XCTAssertEqual(try load("command_palettes: {name: x}").problems, [
            ConfigProblem(path: root, line: 1, message: "command_palettes: expected a list"),
        ])
    }

    func testPaletteKeybindingsOverlayTheirOwnDefaults() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+e
          command_palette:
            jump_to: [enter, cmd+b]
            select_next: ctrl+n
            copy_target: []
            copy_path: ctrl+n
            reveal_in_finder: cmd+r
        """)
        let keys = config.paletteKeybinds
        XCTAssertEqual(keys.triggers[.jumpTo], [trigger("enter"), trigger("cmd+b")])
        XCTAssertEqual(keys.triggers[.selectNext], [trigger("ctrl+n")])
        XCTAssertEqual(keys.triggers[.selectPrev], [trigger("up"), trigger("ctrl+k")])
        XCTAssertEqual(keys.triggers[.copyTarget], [])
        XCTAssertEqual(keys.triggers[.copyPath], [])
        XCTAssertEqual(keys.triggers[.showActions], [trigger("cmd+k")])
        // Only while a palette is open: the global keybinds are untouched.
        XCTAssertEqual(config.keybinds.triggers[.toggleBrowser], [trigger("cmd+e")])
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 7, message: "ctrl+n is already bound to select_next"),
            ConfigProblem(path: root, line: 8, message: "unknown Command Palette action \"reveal_in_finder\""),
        ])
    }

    func testSessionPathsNeedAFolderAndAWholeDepth() throws {
        let config = try load("""
        sessions:
          paths:
            - path: ~/projects/Defold/
              depth: 1
            - path: /srv/repos
              depth: 2
            - path: "~"
            - path: projects
            - path: ~/work
              depth: -1
            - path: ~/work
              depth: 1.5
            - path: ~/gems
              recursive: true
            - depth: 1
          roots: []
        """)
        XCTAssertEqual(config.sessionPaths, [
            SessionPathRoot(path: "~/projects/Defold/", depth: 1),
            SessionPathRoot(path: "/srv/repos", depth: 2),
            SessionPathRoot(path: "~", depth: 0),
        ])
        XCTAssertEqual(config.problems.map(\.line), [8, 10, 12, 14, 15, 16])
        XCTAssertEqual(config.problems.map(\.message), [
            "Session Path path: expected an absolute path or one starting with ~/",
            "Session Path depth: expected a whole number of 0 or more",
            "Session Path depth: expected a whole number of 0 or more",
            "unknown Session Path key \"recursive\"",
            "Session Path path: expected an absolute path or one starting with ~/",
            "unknown key \"sessions.roots\"",
        ])
    }

    func testARemoteConfigSkipsTheSectionsAboutTheApp() throws {
        let text = """
        ghostty:
          config_file: ghostty.conf
        remote_environments:
          - name: Home
            host: home
            username: me
        ui:
          header_height: 40
        sessions:
          paths:
            - path: ~/src
              depth: 1
        """
        let remote = try load(text, isRemote: true)
        XCTAssertNil(remote.ghosttyConfigFile)
        XCTAssertEqual(remote.remoteEnvironments, [])
        XCTAssertEqual(remote.headerHeight, 40)
        XCTAssertEqual(remote.sessionPaths, [SessionPathRoot(path: "~/src", depth: 1)])
        XCTAssertEqual(remote.problems, [])

        let local = try load(text)
        XCTAssertNotNil(local.ghosttyConfigFile)
        XCTAssertEqual(local.remoteEnvironments.map(\.name), ["Home"])
    }
}
