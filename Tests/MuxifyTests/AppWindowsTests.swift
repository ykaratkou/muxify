import AppKit
import XCTest

final class AppWindowsTests: XCTestCase {
    private static let config = """
    remote_environments:
      - name: Home
        host: home.example
        username: test
    """

    @MainActor func testDefaultScenesHaveIndependentStoresAndTerminalHosts() throws {
        try withWindows { windows, _ in
            let firstRequest = windows.defaultWindowRequest()
            let first = windows.store(for: firstRequest)
            let secondRequest = windows.defaultWindowRequest()
            let second = windows.store(for: secondRequest)
            XCTAssertNotEqual(firstRequest.id, secondRequest.id)
            XCTAssertFalse(first === second)
            XCTAssertFalse(first.terminalHost === second.terminalHost)

            let firstWindow = FocusWindow()
            let secondWindow = FocusWindow()
            firstWindow.contentView = first.terminalHost
            secondWindow.contentView = second.terminalHost
            defer { firstWindow.contentView = nil; secondWindow.contentView = nil }
            XCTAssertTrue(first.terminalHost.window === firstWindow)
            XCTAssertTrue(second.terminalHost.window === secondWindow)
        }
    }

    @MainActor func testOnlyFirstDefaultSceneUsesTheRememberedEnvironment() throws {
        try withWindows { windows, _ in
            UserDefaults.standard.set("Home", forKey: "selectedEnvironment")
            let remembered = AppWindows(configStore: windows.configStore)
            let first = remembered.defaultWindowRequest()
            XCTAssertEqual(first.environmentName, "Home")
            _ = remembered.store(for: first)
            let second = remembered.defaultWindowRequest()
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertNil(second.environmentName)
            let finished = expectation(description: "remembered workspace cleanup")
            remembered.shutdown { finished.fulfill() }
            wait(for: [finished], timeout: 3)
        }
    }

    @MainActor func testDuplicateNativeRegistrationCannotReplaceTheOwningWindow() throws {
        try withWindows { windows, _ in
            let request = windows.defaultWindowRequest()
            let store = windows.store(for: request)
            let owner = FocusWindow()
            let duplicate = FocusWindow()
            owner.contentView = store.terminalHost
            defer { owner.contentView = nil }
            windows.register(owner, for: request.id)
            windows.register(duplicate, for: request.id)
            windows.openWindow = { _ in XCTFail("The original native window must remain registered") }
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: duplicate)
            windows.selectEnvironment(named: nil)
            XCTAssertEqual(owner.focusRequests, 1)
            XCTAssertEqual(duplicate.focusRequests, 0)
            XCTAssertTrue(windows.focusedStore === store)
            XCTAssertTrue(store.terminalHost.window === owner)
        }
    }

    @MainActor func testRepeatedSessionUrlsFocusTheExistingLocalWithoutMovingItsTerminalHost() throws {
        try withWindows { windows, _ in
            let firstRequest = windows.defaultWindowRequest()
            let first = windows.store(for: firstRequest)
            let firstWindow = FocusWindow()
            firstWindow.contentView = first.terminalHost
            let secondRequest = AppWindowRequest()
            let second = windows.store(for: secondRequest)
            let secondWindow = FocusWindow()
            secondWindow.contentView = second.terminalHost
            defer { firstWindow.contentView = nil; secondWindow.contentView = nil }
            windows.register(firstWindow, for: firstRequest.id)
            windows.register(secondWindow, for: secondRequest.id)
            firstWindow.makeKeyAndOrderFront(nil)
            windows.openWindow = { _ in XCTFail("A session URL must reuse the focused Local App Window") }
            let url = try XCTUnwrap(URL(string: "muxify://select?session=my%20project"))
            for _ in 0..<3 { windows.handle(url) }
            XCTAssertEqual(firstWindow.focusRequests, 4)
            XCTAssertEqual(secondWindow.focusRequests, 0)
            XCTAssertTrue(windows.focusedStore === first)
            XCTAssertTrue(first.terminalHost.window === firstWindow)
            XCTAssertTrue(second.terminalHost.window === secondWindow)
        }
    }

    @MainActor func testSessionUrlReusesLocalWhenRemoteIsFocused() throws {
        try withWindows { windows, _ in
            let localRequest = AppWindowRequest()
            let local = windows.store(for: localRequest)
            let remoteRequest = AppWindowRequest(environmentName: "Home")
            let remote = windows.store(for: remoteRequest)
            let localWindow = FocusWindow()
            let remoteWindow = FocusWindow()
            localWindow.contentView = local.terminalHost
            remoteWindow.contentView = remote.terminalHost
            defer { localWindow.contentView = nil; remoteWindow.contentView = nil }
            windows.register(localWindow, for: localRequest.id)
            windows.register(remoteWindow, for: remoteRequest.id)
            remoteWindow.makeKeyAndOrderFront(nil)
            windows.openWindow = { _ in XCTFail("A Local App Window already exists") }
            windows.handle(try XCTUnwrap(URL(string: "muxify://select?session=main")))
            XCTAssertEqual(localWindow.focusRequests, 1)
            XCTAssertTrue(windows.focusedStore === local)
            XCTAssertEqual(remote.environmentName, "Home")
            XCTAssertTrue(remote.terminalHost.window === remoteWindow)
        }
    }

    @MainActor func testRemoteSelectionOpensOnceAndLeavesTheOriginalWorkspaceLocal() throws {
        try withWindows { windows, _ in
            let original = windows.store(for: AppWindowRequest())
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            original.selectEnvironment(named: "Home")
            original.selectEnvironment(named: "Home")
            XCTAssertEqual(opened.count, 2)
            XCTAssertEqual(opened[0].id, opened[1].id)
            let remote = windows.store(for: opened[0])
            XCTAssertTrue(remote === windows.store(for: opened[1]))
            XCTAssertNil(original.activeEnvironment)
            XCTAssertEqual(remote.environmentName, "Home")
        }
    }

    @MainActor func testExistingRemoteIsFocusedAndFocusedCommandsFollowItsWorkspace() throws {
        try withWindows { windows, _ in
            let localRequest = AppWindowRequest()
            let remoteRequest = AppWindowRequest(environmentName: "Home")
            let local = windows.store(for: localRequest)
            let remote = windows.store(for: remoteRequest)
            let localWindow = FocusWindow()
            let remoteWindow = FocusWindow()
            windows.register(localWindow, for: localRequest.id)
            windows.register(remoteWindow, for: remoteRequest.id)
            windows.openWindow = { _ in XCTFail("An existing Environment should not create another window") }
            localWindow.makeKeyAndOrderFront(nil)
            XCTAssertTrue(windows.focusedStore === local)
            windows.selectEnvironment(named: "Home")
            XCTAssertEqual(remoteWindow.focusRequests, 1)
            XCTAssertTrue(windows.focusedStore === remote)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedEnvironment"), "Home")
            let wasVisible = remote.sidebarVisible
            windows.focusedStore?.toggleSidebar()
            XCTAssertEqual(remote.sidebarVisible, !wasVisible)
            XCTAssertNotEqual(local.sidebarVisible, remote.sidebarVisible)
        }
    }

    @MainActor func testNewAppWindowFromRemoteAlwaysOpensFreshLocalWindows() throws {
        try withWindows { windows, _ in
            let remote = windows.store(for: AppWindowRequest(environmentName: "Home"))
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            remote.ghosttyNewWindow()
            remote.ghosttyNewWindow()
            XCTAssertEqual(opened.count, 2)
            XCTAssertNotEqual(opened[0].id, opened[1].id)
            XCTAssertTrue(opened.allSatisfy { $0.environmentName == nil })
            XCTAssertEqual(remote.environmentName, "Home")
        }
    }

    @MainActor func testClosingOneWindowDoesNotRetireAnotherAndCanReopenRemote() throws {
        try withWindows { windows, _ in
            let localRequest = AppWindowRequest()
            let remoteRequest = AppWindowRequest(environmentName: "Home")
            let local = windows.store(for: localRequest)
            let remote = windows.store(for: remoteRequest)
            let remoteWindow = FocusWindow()
            windows.register(remoteWindow, for: remoteRequest.id)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: remoteWindow)
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            remote.selectEnvironment(named: "Home")
            XCTAssertTrue(opened.isEmpty, "Closed workspaces must stop accepting actions")
            local.selectEnvironment(named: "Home")
            XCTAssertEqual(opened.count, 1)
            XCTAssertNotEqual(opened[0].id, remoteRequest.id)
            XCTAssertTrue(local === windows.store(for: localRequest))
        }
    }

    @MainActor func testConfigRemovalFallsBackOnlyTheAffectedWindowToLocal() throws {
        try withWindows { windows, path in
            let request = AppWindowRequest(environmentName: "Home")
            let remote = windows.store(for: request)
            try "remote_environments: []".write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            remote.reconcileEnvironments()
            windows.updateEnvironment(for: request.id)
            XCTAssertNil(remote.activeEnvironment)
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            windows.selectEnvironment(named: "Home")
            XCTAssertTrue(opened.isEmpty)
            windows.selectEnvironment(named: nil)
            XCTAssertEqual(opened.first?.id, request.id)
        }
    }

    @MainActor func testMacOSUrlTargetsLocalEvenWhenRemoteIsFocused() throws {
        try withWindows { windows, _ in
            let remoteRequest = AppWindowRequest(environmentName: "Home")
            let remote = windows.store(for: remoteRequest)
            let remoteWindow = FocusWindow()
            windows.register(remoteWindow, for: remoteRequest.id)
            remoteWindow.makeKeyAndOrderFront(nil)
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            windows.handle(try XCTUnwrap(URL(string: "muxify://open?window=@1&url=https://example.com")))
            let localRequest = try XCTUnwrap(opened.first)
            XCTAssertNil(localRequest.environmentName)
            XCTAssertEqual(windows.store(for: localRequest).browser(for: "@1").stored.tabURLs, ["https://example.com"])
            XCTAssertTrue(remote.browser(for: "@1").tabs.isEmpty)
        }
    }

    @MainActor func testBrowserViewsAreIndependentAndOnlyChangedStateIsFlushed() throws {
        try withWindows { windows, _ in
            let first = windows.store(for: AppWindowRequest())
            let second = windows.store(for: AppWindowRequest())
            let firstBrowser = first.browser(for: "@1")
            let secondBrowser = second.browser(for: "@1")
            XCTAssertFalse(firstBrowser === secondBrowser)
            XCTAssertTrue(first.pendingBrowserCommands.isEmpty)
            XCTAssertTrue(second.pendingBrowserCommands.isEmpty)
            firstBrowser.newTab()
            XCTAssertEqual(first.pendingBrowserCommands, [firstBrowser.stored.setOptionArgs(windowID: "@1")])
            XCTAssertTrue(second.pendingBrowserCommands.isEmpty)
        }
    }

    @MainActor func testOnlyOneWindowPerEnvironmentConsumesBrowserRequests() throws {
        try withWindows { windows, _ in
            let firstRequest = AppWindowRequest()
            let secondRequest = AppWindowRequest()
            let first = windows.store(for: firstRequest)
            let second = windows.store(for: secondRequest)
            let remote = windows.store(for: AppWindowRequest(environmentName: "Home"))
            XCTAssertEqual(first.shouldConsumeOpenRequests?(), false)
            XCTAssertEqual(second.shouldConsumeOpenRequests?(), true)
            XCTAssertEqual(remote.shouldConsumeOpenRequests?(), true)
            let native = FocusWindow()
            windows.register(native, for: firstRequest.id)
            native.makeKeyAndOrderFront(nil)
            XCTAssertEqual(first.shouldConsumeOpenRequests?(), true)
            XCTAssertEqual(second.shouldConsumeOpenRequests?(), false)
            XCTAssertEqual(remote.shouldConsumeOpenRequests?(), true)
        }
    }

    @MainActor func testAClosingSwiftUiSceneCannotResurrectItsWindowReservation() throws {
        try withWindows { windows, _ in
            let request = AppWindowRequest(environmentName: "Home")
            _ = windows.store(for: request)
            let native = FocusWindow()
            windows.register(native, for: request.id)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: native)
            let retired = expectation(description: "closed window retired")
            windows.store(for: request).shutdown { retired.fulfill() }
            wait(for: [retired], timeout: 3)
            let stale = windows.store(for: request)
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            stale.selectEnvironment(named: "Home")
            XCTAssertTrue(opened.isEmpty)
            windows.selectEnvironment(named: "Home")
            XCTAssertNotEqual(opened.first?.id, request.id)
        }
    }

    @MainActor func testShutdownRejectsNewWindowsAndCompletesAsynchronously() throws {
        try withWindows { windows, _ in
            _ = windows.store(for: AppWindowRequest())
            _ = windows.store(for: AppWindowRequest(environmentName: "Home"))
            windows.openWindow = { _ in XCTFail("Do not open windows during quit") }
            let finished = expectation(description: "all window cleanup finished")
            var returned = false
            windows.shutdown {
                XCTAssertTrue(returned)
                XCTAssertTrue(Thread.isMainThread)
                finished.fulfill()
            }
            returned = true
            windows.newWindow()
            windows.selectEnvironment(named: "Home")
            wait(for: [finished], timeout: 3)
        }
    }

    @MainActor func testKeybindingsUseOnlyTheOriginatingNativeWindowAndApplyLiveOverrides() throws {
        try withWindows { windows, path in
            let first = windows.store(for: AppWindowRequest())
            let second = windows.store(for: AppWindowRequest(environmentName: "Home"))
            let native = FocusWindow()
            native.contentView = first.terminalHost
            defer { native.contentView = nil }
            var opened: [AppWindowRequest] = []
            windows.openWindow = { opened.append($0) }
            let commandN = try keyEvent(window: native, flags: .command)
            XCTAssertTrue(second.handleKeyEvent(commandN) === commandN)
            XCTAssertNil(first.handleKeyEvent(commandN))
            XCTAssertEqual(opened.count, 1)
            XCTAssertNil(opened.first?.environmentName)

            try (Self.config + "\nkeybindings:\n  new_app_window: cmd+shift+n\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            XCTAssertNil(first.handleKeyEvent(commandN), "Do not leak the removed default through to Ghostty")
            XCTAssertEqual(opened.count, 1)
            XCTAssertNil(first.handleKeyEvent(try keyEvent(window: native, flags: [.command, .shift])))
            XCTAssertEqual(opened.count, 2)

            try (Self.config + "\nkeybindings:\n  new_app_window: []\n  toggle_sidebar: cmd+n\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            let wasVisible = first.sidebarVisible
            XCTAssertNil(first.handleKeyEvent(commandN))
            XCTAssertEqual(first.sidebarVisible, !wasVisible)
            XCTAssertEqual(opened.count, 2)
        }
    }

    @MainActor func testFocusTerminalKeybindingRoutesOnlyItsWindowAndAppliesLiveOverrides() throws {
        try withWindows { windows, path in
            let first = windows.store(for: AppWindowRequest())
            let second = windows.store(for: AppWindowRequest(environmentName: "Home"))
            let native = FocusWindow()
            native.contentView = first.terminalHost
            defer { native.contentView = nil }
            // A text responder represents Browser/address-bar focus, without
            // starting Ghostty, WebKit or a tmux connection.
            let text = NSTextView(frame: native.contentView!.bounds)
            first.terminalHost.addSubview(text)
            XCTAssertTrue(native.makeFirstResponder(text))
            let controlBackquote = try keyEvent(window: native, flags: .control, characters: "`", keyCode: 0x32)
            XCTAssertTrue(second.handleKeyEvent(controlBackquote) === controlBackquote)
            XCTAssertNil(first.handleKeyEvent(controlBackquote))
            let commandBackquote = try keyEvent(window: native, flags: .command, characters: "`", keyCode: 0x32)
            let reverseCycle = try keyEvent(window: native, flags: [.command, .shift], characters: "~", keyCode: 0x32)
            XCTAssertTrue(first.handleKeyEvent(commandBackquote) === commandBackquote)
            XCTAssertTrue(first.handleKeyEvent(reverseCycle) === reverseCycle)

            try (Self.config + "\nkeybindings:\n  focus_terminal: [ctrl+cmd+t, cmd+backquote]\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            XCTAssertTrue(first.handleKeyEvent(controlBackquote) === controlBackquote)
            let remapped = try keyEvent(window: native, flags: [.control, .command], characters: "t", keyCode: 0x11)
            XCTAssertNil(first.handleKeyEvent(remapped))
            XCTAssertNil(first.handleKeyEvent(commandBackquote), "An explicit binding may reclaim the old shortcut")

            try (Self.config + "\nkeybindings:\n  focus_terminal: []\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            for event in [controlBackquote, commandBackquote, reverseCycle, remapped] {
                XCTAssertTrue(first.handleKeyEvent(event) === event, "No hardcoded fallback after disabling")
            }
        }
    }

    @MainActor func testSidebarTypographyReloadIsSharedAndDoesNotChangeWindowState() throws {
        try withWindows { windows, path in
            let localRequest = AppWindowRequest()
            let remoteRequest = AppWindowRequest(environmentName: "Home")
            let local = windows.store(for: localRequest)
            let remote = windows.store(for: remoteRequest)
            local.sessionsVisible = false
            remote.agentsVisible = false
            let localState = (local.selectedWindowID, local.sidebarVisible, local.sessionsVisible, local.agentsVisible)
            let remoteState = (remote.selectedWindowID, remote.sidebarVisible, remote.sessionsVisible, remote.agentsVisible)
            let defaults = UserDefaults.standard
            let expansion = defaults.object(forKey: "expandedSessions") as? [String]
            let split = defaults.object(forKey: "sidebarAgentsFraction") as? Double

            try (Self.config + "\nui:\n  sidebar:\n    font_size: 18\n    font_family: system\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            XCTAssertEqual(windows.configStore.config.sidebarTypography, SidebarTypography(fontSize: 18))
            XCTAssertTrue(local === windows.store(for: localRequest))
            XCTAssertTrue(remote === windows.store(for: remoteRequest))
            XCTAssertEqual(local.selectedWindowID, localState.0)
            XCTAssertEqual(local.sidebarVisible, localState.1)
            XCTAssertEqual(local.sessionsVisible, localState.2)
            XCTAssertEqual(local.agentsVisible, localState.3)
            XCTAssertEqual(remote.selectedWindowID, remoteState.0)
            XCTAssertEqual(remote.sidebarVisible, remoteState.1)
            XCTAssertEqual(remote.sessionsVisible, remoteState.2)
            XCTAssertEqual(remote.agentsVisible, remoteState.3)
            XCTAssertEqual(remote.environmentName, "Home")
            XCTAssertEqual(defaults.object(forKey: "expandedSessions") as? [String], expansion)
            XCTAssertEqual(defaults.object(forKey: "sidebarAgentsFraction") as? Double, split)

            try (Self.config + "\nui: [").write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            XCTAssertEqual(windows.configStore.config.sidebarTypography, SidebarTypography(fontSize: 18))
            XCTAssertEqual(windows.configStore.problems.count, 1)
            try Self.config.write(toFile: path, atomically: true, encoding: .utf8)
            windows.configStore.reload()
            XCTAssertEqual(windows.configStore.config.sidebarTypography, SidebarTypography())
            XCTAssertEqual(windows.configStore.problems, [])
        }
    }

    @MainActor private func keyEvent(window: NSWindow, flags: NSEvent.ModifierFlags,
                                    characters: String = "n", keyCode: UInt16 = 0x2D) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @MainActor private func withWindows(_ body: (AppWindows, String) throws -> Void) throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["selectedEnvironment", "sidebarVisible", "sessionsVisible", "agentsVisible", "browserURLs", "browserVisible", "browserWidth"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-window-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.yaml").path
        try Self.config.write(toFile: path, atomically: true, encoding: .utf8)
        defaults.removeObject(forKey: "selectedEnvironment")
        let windows = AppWindows(configStore: ConfigStore(path: path))
        defer {
            let finished = expectation(description: "fixture window cleanup")
            windows.shutdown { finished.fulfill() }
            wait(for: [finished], timeout: 3)
        }
        try body(windows, path)
    }

    /// Records native focus without showing UI or starting any terminals.
    private final class FocusWindow: NSWindow {
        var focusRequests = 0
        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
            isReleasedWhenClosed = false
        }
        override func makeKeyAndOrderFront(_ sender: Any?) {
            focusRequests += 1
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self)
        }
    }
}
