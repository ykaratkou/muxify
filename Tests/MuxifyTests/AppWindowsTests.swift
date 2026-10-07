import AppKit
import XCTest

final class AppWindowsTests: XCTestCase {
    private static let config = """
    remote_environments:
      - name: Home
        host: home.example
        username: test
    """

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

    @MainActor private func keyEvent(window: NSWindow, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 0x2D))
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
