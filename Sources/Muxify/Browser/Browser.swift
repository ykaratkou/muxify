import Foundation
import Observation

/// A Window's Browser: its Tabs and whether it is open. Every change is
/// reported through `onChange` so it can be written back onto the tmux
/// Window (ADR 0003).
@Observable
final class Browser {
    let windowID: String
    /// The local scanner must never use a remote Window ID against local tmux.
    let discoversLocalServers: Bool
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabID: UUID?
    private(set) var isOpen = false
    /// Set to ask the panel to focus the active Tab's address field.
    var wantsAddressFocus = false

    @ObservationIgnored var onChange: ((Browser) -> Void)?

    init(windowID: String, stored: StoredBrowser, discoversLocalServers: Bool = true) {
        self.windowID = windowID
        self.discoversLocalServers = discoversLocalServers
        tabs = stored.tabURLs.map { url in
            makeTab(url == "about:blank" ? nil : URL(string: url))
        }
        if !tabs.isEmpty {
            activeTabID = tabs[min(max(stored.activeTab, 0), tabs.count - 1)].id
        }
        isOpen = stored.isOpen && !tabs.isEmpty
    }

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    var stored: StoredBrowser {
        StoredBrowser(
            tabURLs: tabs.map { $0.hasPage ? $0.urlString : "about:blank" },
            activeTab: tabs.firstIndex { $0.id == activeTabID } ?? 0,
            isOpen: isOpen
        )
    }

    /// Opening an empty Browser gives it a blank Tab to type into.
    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        if open, tabs.isEmpty {
            newTab()
            return
        }
        isOpen = open
        if open, activeTab?.hasPage == false { wantsAddressFocus = true }
        // A hidden blank Tab is nothing worth keeping (or badging in the sidebar).
        if !open { dropBlankTabs() }
        changed()
    }

    private func dropBlankTabs() {
        let blank = tabs.filter { !$0.hasPage }
        guard !blank.isEmpty else { return }
        blank.forEach { $0.close() }
        tabs.removeAll { !$0.hasPage }
        if activeTab == nil { activeTabID = tabs.last?.id }
    }

    /// Shows `url` in a Tab and opens the Browser. Switches to a Tab that
    /// already has the URL, reuses the active Tab if it is still blank, and
    /// otherwise adds a new Tab.
    func open(_ url: URL) {
        let key = BrowserTab.matchKey(url.absoluteString)
        if let existing = tabs.first(where: { $0.hasPage && BrowserTab.matchKey($0.urlString) == key }) {
            activeTabID = existing.id
        } else if let blank = activeTab, !blank.hasPage {
            blank.load(url)
        } else {
            let tab = makeTab(url)
            tabs.append(tab)
            activeTabID = tab.id
        }
        isOpen = true
        changed()
    }

    func newTab() {
        let tab = makeTab(nil)
        tabs.append(tab)
        activeTabID = tab.id
        isOpen = true
        wantsAddressFocus = true
        changed()
    }

    /// Closing the last Tab closes the Browser.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabID = nil
            isOpen = false
        } else if activeTabID == tab.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        changed()
    }

    func closeActiveTab() {
        if let activeTab { close(activeTab) }
    }

    func select(_ tab: BrowserTab) {
        guard activeTabID != tab.id else { return }
        activeTabID = tab.id
        changed()
    }

    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Releases every Tab's web content (the Window is gone).
    func tearDown() {
        tabs.forEach { $0.close() }
    }

    private func makeTab(_ url: URL?) -> BrowserTab {
        let tab = BrowserTab(url: url)
        tab.onOpenInNewTab = { [weak self] in self?.open($0) }
        tab.onURLChange = { [weak self] in self?.changed() }
        return tab
    }

    private func changed() {
        onChange?(self)
    }
}
