import XCTest

final class ConfigTests: XCTestCase {
    private let root = "/cfg/muxify/config.yaml"

    private func load(_ files: [String: String]) throws -> Config {
        try Config.load(path: root) { files[$0] }.get()
    }

    private func load(_ text: String) throws -> Config {
        try load([root: text])
    }

    private func trigger(_ string: String) -> KeyTrigger {
        try! KeyTrigger(string)
    }

    func testMissingOrEmptyFileGivesTheDefaults() throws {
        for config in [try load([:]), try load(""), try load("# nothing here\n\n")] {
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+s")), .toggleSidebar)
            XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+s")), .toggleSidebar)
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+b")), .toggleBrowser)
            XCTAssertEqual(config.keybinds.action(for: trigger("cmd+n")), .newAppWindow)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
            XCTAssertEqual(config.headerHeight, 30)
            XCTAssertNil(config.ghosttyConfigFile)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testHeaderHeightAcceptsWholeAndFractionalPoints() throws {
        for height in [24.0, 26, 28, 28.5, 30, 40, 128] {
            let config = try load("ui:\n  header_height: \(height)")
            XCTAssertEqual(config.headerHeight, height)
            XCTAssertEqual(config.keybinds, .defaults)
            XCTAssertEqual(config.problems, [])
        }
    }

    func testNewAppWindowCanBeRemappedDisabledOrHaveItsDefaultClaimed() throws {
        let remapped = try load("keybindings:\n  new_app_window: [cmd+shift+n, ctrl+cmd+n]")
        XCTAssertNil(remapped.keybinds.action(for: trigger("cmd+n")))
        XCTAssertEqual(remapped.keybinds.action(for: trigger("cmd+shift+n")), .newAppWindow)
        XCTAssertEqual(remapped.keybinds.action(for: trigger("ctrl+cmd+n")), .newAppWindow)
        XCTAssertTrue(remapped.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        let disabled = try load("keybindings:\n  new_app_window: []")
        XCTAssertNil(disabled.keybinds.firstTrigger(for: .newAppWindow))
        XCTAssertTrue(disabled.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        let claimed = try load("keybindings:\n  toggle_browser: cmd+n")
        XCTAssertEqual(claimed.keybinds.action(for: trigger("cmd+n")), .toggleBrowser)
        XCTAssertNil(claimed.keybinds.firstTrigger(for: .newAppWindow))
        XCTAssertFalse(claimed.keybinds.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        XCTAssertFalse(Keybinds.defaults.suppressesDefaultAppWindowShortcut(trigger("cmd+n")))
        for config in [remapped, disabled, claimed] { XCTAssertTrue(config.problems.isEmpty) }
    }

    func testInvalidHeaderHeightUsesTheDefaultAndReportsTheLine() throws {
        for value in ["23.99", "0", "-1", ".inf", "-.inf", ".nan", "1e309", "wrong", "false", "", "null", "[28]", "{height: 28}", "\"28\""] {
            let config = try load("ui:\n  header_height: \(value)\nkeybindings:\n  toggle_sidebar: cmd+e")
            XCTAssertEqual(config.headerHeight, 30, value)
            XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+e"), value)
            XCTAssertEqual(config.problems, [
                ConfigProblem(path: root, line: 2, message: "ui.header_height: expected a finite number of at least 24 points"),
            ], value)
        }
    }

    func testUISectionRequiresAMappingAndReportsUnknownKeys() throws {
        XCTAssertEqual(try load("ui: 28").problems, [
            ConfigProblem(path: root, line: 1, message: "ui: expected a mapping"),
        ])
        let config = try load("ui:\n  header_height: 26\n  header_width: 80")
        XCTAssertEqual(config.headerHeight, 26)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "unknown key \"ui.header_width\""),
        ])
    }

    func testHeaderHeightReloadAndSyntaxErrorRecovery() throws {
        var loaded = LoadedConfig()
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 26" })
        XCTAssertEqual(loaded.config.headerHeight, 26)
        loaded.update(with: Config.load(path: root) { _ in "ui: [" })
        XCTAssertEqual(loaded.config.headerHeight, 26)
        XCTAssertEqual(loaded.problems.count, 1)
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 32" })
        XCTAssertEqual(loaded.config.headerHeight, 32)
        XCTAssertEqual(loaded.problems, [])
        loaded.update(with: Config.load(path: root) { _ in "keybindings: {}" })
        XCTAssertEqual(loaded.config.headerHeight, 30)
        loaded.update(with: Config.load(path: root) { _ in "ui:\n  header_height: 26" })
        loaded.update(with: Config.load(path: root) { _ in nil })
        XCTAssertEqual(loaded.config.headerHeight, 30)
    }

    func testNumberedWindowKeybindingsDefaultToCommandOneThroughNine() throws {
        let actions: [ConfigAction] = [
            .selectWindow1, .selectWindow2, .selectWindow3,
            .selectWindow4, .selectWindow5, .selectWindow6,
            .selectWindow7, .selectWindow8, .selectWindow9,
        ]
        for config in [try load([:]), try load("")] {
            for (offset, action) in actions.enumerated() {
                let key = trigger("cmd+\(offset + 1)")
                XCTAssertEqual(config.keybinds.action(for: key), action)
                XCTAssertEqual(config.keybinds.firstTrigger(for: action), key)
            }
        }
    }

    func testNumberedWindowKeybindingsCanBeRemappedOrDisabled() throws {
        let config = try load("""
        keybindings:
          select_window_1: [alt+1, ctrl+cmd+digit_1]
          select_window_2: []
        """)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+1")))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+2")))
        XCTAssertEqual(config.keybinds.action(for: trigger("alt+1")), .selectWindow1)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+1")), .selectWindow1)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectWindow1), trigger("alt+1"))
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow2))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+3")), .selectWindow3)
        XCTAssertEqual(config.problems, [])
    }

    func testNumberedWindowDefaultsCanBeClaimedByAnotherAction() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+1
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .toggleBrowser)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow1))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+2")), .selectWindow2)
        XCTAssertEqual(config.problems, [])
    }

    func testNumberedWindowKeybindingsReportConflicts() throws {
        let config = try load("""
        keybindings:
          select_window_1: cmd+e
          select_window_2: cmd+e
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .selectWindow1)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow2))
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 3, message: "cmd+e is already bound to select_window_1"),
        ])
    }

    func testNextAndPreviousWindowActionsAreUnboundByDefault() throws {
        let config = try load([:])
        for action in [ConfigAction.selectNextWindow, .selectPrevWindow] {
            XCTAssertEqual(config.keybinds.triggers[action], [])
            XCTAssertNil(config.keybinds.firstTrigger(for: action))
        }
        XCTAssertNil(config.keybinds.action(for: trigger("ctrl+cmd+right")))
        XCTAssertNil(config.keybinds.action(for: trigger("ctrl+cmd+left")))
        XCTAssertEqual(config.problems, [])
    }

    func testNextAndPreviousWindowActionsAcceptBindings() throws {
        let config = try load("""
        keybindings:
          select_next_window: [ctrl+cmd+right, cmd+shift+right_bracket]
          select_prev_window: ctrl+cmd+left
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+right")), .selectNextWindow)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+right_bracket")), .selectNextWindow)
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+left")), .selectPrevWindow)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectNextWindow), trigger("ctrl+cmd+right"))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .selectPrevWindow), trigger("ctrl+cmd+left"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .selectWindow1)
        XCTAssertEqual(config.problems, [])
    }

    func testNextAndPreviousWindowActionsCanBeExplicitlyDisabled() throws {
        let config = try load("""
        keybindings:
          select_next_window: []
          select_prev_window: []
        """)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.problems, [])
    }

    func testNextWindowActionCanClaimANumberedWindowDefault() throws {
        let config = try load("""
        keybindings:
          select_next_window: cmd+1
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+1")), .selectNextWindow)
        XCTAssertNil(config.keybinds.firstTrigger(for: .selectWindow1))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+2")), .selectWindow2)
        XCTAssertEqual(config.problems, [])
    }

    func testNamingAnActionReplacesItsDefaults() throws {
        let config = try load("""
        keybindings:
          toggle_sidebar: ctrl+cmd+s
        """)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+s")))
        XCTAssertEqual(config.keybinds.action(for: trigger("ctrl+cmd+s")), .toggleSidebar)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("ctrl+cmd+s"))
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+b")), .toggleBrowser)
        XCTAssertEqual(config.problems, [])
    }

    func testAListBindsEveryTriggerAndTheFirstIsShown() throws {
        let config = try load("""
        keybindings:
          toggle_browser: [cmd+e, cmd+shift+b]
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+shift+b")), .toggleBrowser)
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleBrowser), trigger("cmd+e"))
    }

    func testAnEmptyListLeavesTheActionWithNoKeybinding() throws {
        let config = try load("""
        keybindings:
          toggle_browser: []
        """)
        XCTAssertNil(config.keybinds.firstTrigger(for: .toggleBrowser))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
        XCTAssertEqual(config.problems, [])
    }

    func testATriggerListedForOneActionIsTakenFromTheDefaultsOfAnother() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+s
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+s")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("ctrl+cmd+s"))
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+b")))
        XCTAssertEqual(config.problems, [])
    }

    func testTheSameTriggerUnderTwoActionsStaysWithTheFirst() throws {
        let config = try load("""
        keybindings:
          toggle_browser: cmd+e
          toggle_sidebar:
            - cmd+e
            - cmd+j
        """)
        XCTAssertEqual(config.keybinds.action(for: trigger("cmd+e")), .toggleBrowser)
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+j"))
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 4, message: "cmd+e is already bound to toggle_browser"),
        ])
    }

    func testProblemLinesCountFromOne() throws {
        XCTAssertEqual(try load("nope: 1").problems, [
            ConfigProblem(path: root, line: 1, message: "unknown section \"nope\""),
        ])
    }

    func testValuesThatCannotApplyAreProblemsAndTheRestApplies() throws {
        let config = try load("""
        fonts:
          size: 12
        ghostty:
          theme: dark
        # comment
        keybindings:
          toggle_everything: cmd+e
          toggle_sidebar: hyper+s
          toggle_browser:
            - cmd+j
            - [cmd+k]
            - meta+b
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 1, message: "unknown section \"fonts\""),
            ConfigProblem(path: root, line: 4, message: "unknown key \"ghostty.theme\""),
            ConfigProblem(path: root, line: 7, message: "unknown action \"toggle_everything\""),
            ConfigProblem(path: root, line: 8, message: "bad trigger \"hyper+s\": unknown modifier \"hyper\""),
            ConfigProblem(path: root, line: 11, message: "toggle_browser: expected a trigger or a list of triggers"),
            ConfigProblem(path: root, line: 12, message: "bad trigger \"meta+b\": unknown modifier \"meta\""),
        ])
        XCTAssertNil(config.keybinds.action(for: trigger("cmd+e")))
        XCTAssertEqual(config.keybinds.firstTrigger(for: .toggleSidebar), trigger("cmd+s"))
        XCTAssertEqual(config.keybinds.triggers[.toggleBrowser], [trigger("cmd+j")])
    }

    func testValuesOfTheWrongTypeAreProblems() throws {
        XCTAssertEqual(try load("keybindings: cmd+s").problems, [
            ConfigProblem(path: root, line: 1, message: "keybindings: expected a mapping"),
        ])
        XCTAssertEqual(try load("- keybindings").problems, [
            ConfigProblem(path: root, line: 1, message: "the Config: expected a mapping"),
        ])
        let config = try load("""
        ghostty:
          config_file: [a, b]
        keybindings:
          toggle_sidebar:
          toggle_browser: {cmd: b}
        """)
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 2, message: "ghostty.config_file: expected a path"),
            ConfigProblem(path: root, line: 4, message: "toggle_sidebar: expected a trigger or a list of triggers"),
            ConfigProblem(path: root, line: 5, message: "toggle_browser: expected a trigger or a list of triggers"),
        ])
        XCTAssertNil(config.ghosttyConfigFile)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
    }

    func testGhosttyConfigFileResolvesAgainstTheConfigAndExpandsHome() throws {
        let relative = try load([
            root: "ghostty:\n  config_file: ../ghostty/personal",
            "/cfg/ghostty/personal": "",
        ])
        XCTAssertEqual(relative.ghosttyConfigFile, "/cfg/ghostty/personal")
        XCTAssertEqual(relative.problems, [])

        let home = NSHomeDirectory()
        let fromHome = try load([
            root: "ghostty:\n  config_file: ~/ghostty/work",
            "\(home)/ghostty/work": "",
        ])
        XCTAssertEqual(fromHome.ghosttyConfigFile, "\(home)/ghostty/work")
        XCTAssertEqual(fromHome.problems, [])
    }

    func testAMissingGhosttyConfigFileIsAProblem() throws {
        let config = try load("ghostty:\n  config_file: /nowhere")
        XCTAssertEqual(config.ghosttyConfigFile, "/nowhere")
        XCTAssertEqual(config.problems, [
            ConfigProblem(path: root, line: 2, message: "ghostty.config_file /nowhere: not found"),
        ])
    }

    func testASyntaxErrorFailsTheWholeRead() {
        let badIndent = Config.load(path: root) { _ in "keybindings:\n  toggle_sidebar: cmd+s\n toggle_browser: cmd+b\n" }
        XCTAssertThrowsError(try badIndent.get()) { error in
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.line, 3)
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.path, root)
        }
        let duplicate = Config.load(path: root) { _ in "keybindings:\n  toggle_sidebar: cmd+s\n  toggle_sidebar: cmd+j\n" }
        XCTAssertThrowsError(try duplicate.get()) { error in
            XCTAssertEqual((error as? ConfigSyntaxError)?.problem.message, "duplicate key toggle_sidebar")
        }
    }

    func testASyntaxErrorKeepsTheLastGoodConfigAndShowsOnlyItself() throws {
        var loaded = LoadedConfig()
        loaded.update(with: Config.load(path: root) { _ in "keybindings:\n  toggle_browser: cmd+e\nnope: 1" })
        let good = loaded.config
        XCTAssertEqual(good.keybinds.firstTrigger(for: .toggleBrowser), trigger("cmd+e"))
        XCTAssertEqual(loaded.problems.map(\.message), ["unknown section \"nope\""])

        let syntaxError = Config.load(path: root) { _ in "keybindings: [" }
        loaded.update(with: syntaxError)
        XCTAssertEqual(loaded.config, good)
        XCTAssertThrowsError(try syntaxError.get()) { error in
            XCTAssertEqual(loaded.problems, [(error as! ConfigSyntaxError).problem])
        }

        loaded.update(with: Config.load(path: root) { _ in nil })
        XCTAssertEqual(loaded.config.keybinds, Keybinds.defaults)
        XCTAssertEqual(loaded.problems, [])
    }

    func testTriggersParseGhosttyNames() throws {
        XCTAssertEqual(try KeyTrigger("cmd+shift+left_bracket"), KeyTrigger(modifiers: [.command, .shift], key: .character("[")))
        XCTAssertEqual(try KeyTrigger("ctrl+cmd+s"), KeyTrigger(modifiers: [.control, .command], key: .character("s")))
        XCTAssertEqual(try KeyTrigger("control+command+S"), try KeyTrigger("ctrl+cmd+s"))
        XCTAssertEqual(try KeyTrigger("digit_1"), KeyTrigger(modifiers: [], key: .character("1")))
        XCTAssertEqual(try KeyTrigger("opt+left"), KeyTrigger(modifiers: .option, key: .special(.left)))
        XCTAssertEqual(try KeyTrigger("cmd+shift+left_bracket").symbol, "⇧⌘[")
        XCTAssertEqual(try KeyTrigger("ctrl+cmd+s").symbol, "⌃⌘S")
        XCTAssertThrowsError(try KeyTrigger("cmd+"))
        XCTAssertThrowsError(try KeyTrigger("cmd+nope"))
        XCTAssertThrowsError(try KeyTrigger("meta+s"))
    }

    func testTheTemplateIsAValidConfigThatChangesNothing() throws {
        let config = try load(Config.template)
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.headerHeight, 30)
        XCTAssertNil(config.ghosttyConfigFile)
        XCTAssertEqual(config.problems, [])
    }

    func testTheHeaderHeightTheTemplateShowsIsTheDefault() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            line.hasPrefix("# ui:") || line.hasPrefix("#   header_height:")
        }.map { $0.dropFirst(2) }
        XCTAssertEqual(shown.count, 2)
        let config = try load(shown.joined(separator: "\n"))
        XCTAssertEqual(config.headerHeight, Config().headerHeight)
        XCTAssertEqual(config.problems, [])
    }

    func testTheKeybindingsTheTemplateShowsAreTheDefaults() throws {
        let shown = Config.template.split(separator: "\n").filter { line in
            ConfigAction.allCases.contains { line.hasPrefix("#   \($0.rawValue):") }
        }.map { $0.dropFirst() }
        XCTAssertEqual(shown.count, ConfigAction.allCases.count)
        let config = try load("keybindings:\n" + shown.joined(separator: "\n"))
        XCTAssertEqual(config.keybinds, Keybinds.defaults)
        XCTAssertEqual(config.problems, [])
    }
}

final class ConfigFileSetTests: XCTestCase {
    func testIncludesResolveAgainstTheIncludingFile() {
        let files = [
            "/g/config": """
            font-size = 12
            config-file = keys/more
            """,
            "/g/keys/more": "config-file = \"../last\"",
            "/g/last": "",
        ]
        XCTAssertEqual(ConfigFileSet(root: "/g/config") { files[$0] }.files, ["/g/config", "/g/keys/more", "/g/last"])
    }

    func testMissingIncludesAreStillWatched() {
        let files = ["/g/config": "config-file = ?optional\nconfig-file = required"]
        XCTAssertEqual(ConfigFileSet(root: "/g/config") { files[$0] }.files, ["/g/config", "/g/optional", "/g/required"])
    }

    func testAnIncludeCycleIsReadOnce() {
        let files = ["/g/config": "config-file = other", "/g/other": "config-file = config"]
        var reads: [String] = []
        let set = ConfigFileSet(root: "/g/config") { reads.append($0); return files[$0] }
        XCTAssertEqual(set.files, ["/g/config", "/g/other"])
        XCTAssertEqual(reads, ["/g/config", "/g/other"])
    }
}
