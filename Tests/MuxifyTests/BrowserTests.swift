import AppKit
import XCTest

final class BrowserTests: XCTestCase {
    @MainActor
    func testCopyURLReportsTheCurrentURLAfterNavigation() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let tab = BrowserTab(url: URL(string: "https://example.com"))
        var copied: [String] = []
        tab.onCopyURL = { copied.append($0) }
        let url = "https://example.org/path?query=value#section"
        tab.load(URL(string: url)!)

        tab.copyURL(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), url)
        XCTAssertEqual(copied, [url])
    }

    @MainActor
    func testCopyingABlankTabPreservesTheClipboardAndDoesNotConfirm() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep this", forType: .string)
        let tab = BrowserTab(url: nil)
        tab.onCopyURL = { _ in XCTFail("A blank Tab must not show a copy confirmation") }

        tab.copyURL(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "keep this")
    }

    @MainActor
    func testHidingBrowserPreservesLoadedTabsAndSelection() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "https://example.org"], activeTab: 1, isOpen: true))
        let tabs = browser.tabs
        let selected = browser.activeTabID
        browser.setOpen(false)
        XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(browser.activeTabID, selected)
        XCTAssertEqual(browser.stored.tabURLs, ["https://example.com", "https://example.org"])
        browser.setOpen(true)
        XCTAssertTrue(browser.isOpen)
        XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(browser.activeTabID, selected)
    }

    @MainActor
    func testOrdinaryBrowserHideStillDiscardsEmptyTabs() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "about:blank"], activeTab: 1, isOpen: true))
        browser.setOpen(false)
        XCTAssertEqual(browser.stored.tabURLs, ["https://example.com"])
        XCTAssertEqual(browser.activeTabID, browser.tabs.first?.id)
    }

    @MainActor
    func testExplicitOpenRevealsHiddenBrowserAndSelectsExistingTab() {
        let browser = Browser(windowID: "@1", stored: StoredBrowser(
            tabURLs: ["https://example.com", "about:blank"], activeTab: 1, isOpen: true))
        let existingID = browser.tabs.first?.id
        browser.setOpen(false)
        browser.open(URL(string: "https://example.com")!)
        XCTAssertTrue(browser.isOpen)
        XCTAssertEqual(browser.activeTabID, existingID)
        XCTAssertEqual(browser.tabs.count, 1)
    }
}
