import XCTest

final class BrowserTests: XCTestCase {
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
