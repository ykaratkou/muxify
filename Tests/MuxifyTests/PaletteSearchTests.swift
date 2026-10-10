import XCTest

final class PaletteSearchTests: XCTestCase {
    private func window(_ id: String, session: String, activity: Int, title: String = "", folder: String = "/p/x",
                        agent: String = "") -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$\(session)", sessionName: session, index: 1, name: title.isEmpty ? "w\(id)" : title,
                   paneTitle: "", path: folder, command: "vim", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: activity, agent: agent, storedBrowser: StoredBrowser(), openRequests: [],
                   sessionPath: folder)
    }

    private func agent(_ pane: String, window: TmuxWindow, status: AgentStatus?, unread: Bool = false) -> Agent {
        Agent(paneID: pane, kind: .claude, status: status, unread: unread, windowID: window.id, sessionID: window.sessionID,
              sessionName: window.sessionName, windowIndex: window.index, windowTitle: window.displayTitle)
    }

    private lazy var mux = window("@1", session: "muxify", activity: 30, folder: "/p/muxify")
    private lazy var notes = window("@2", session: "notes", activity: 10, folder: "/p/notes")
    private lazy var web = window("@3", session: "web", activity: 20, folder: "/p/web")

    private func catalog(selected: String? = nil, agents: [Agent] = [], paths: [SessionPath] = []) -> PaletteCatalog {
        PaletteCatalog(windows: [mux, notes, web], agents: agents, sessionPaths: paths, selectedWindowID: selected)
    }

    private func ids(_ items: [PaletteItem]) -> [String] { items.map(\.id) }

    func testAnEmptyQueryListsSessionsByRecencyWithTheCurrentLastThenTheirFreeFolders() {
        let paths = [SessionPath(path: "/p/zoo"), SessionPath(path: "/p/web/"), SessionPath(path: "/p/app")]
        let results = PaletteSearch.results(sources: [.sessions, .windows], query: "",
                                            catalog: catalog(selected: "@1", paths: paths))
        XCTAssertEqual(ids(results), ["session:$web", "session:$notes", "session:$muxify", "path:/p/zoo", "path:/p/app"])
        XCTAssertTrue(results[2].isCurrent)
        XCTAssertNil(results[3].target)
    }

    func testWindowsShowWithAnEmptyQueryOnlyWhenTheirsIsTheOnlyChipOn() {
        XCTAssertEqual(ids(PaletteSearch.results(sources: [.sessions, .windows], query: "", catalog: catalog())),
                       ["session:$muxify", "session:$web", "session:$notes"])
        XCTAssertEqual(ids(PaletteSearch.results(sources: [.windows], query: "", catalog: catalog())),
                       ["window:@1", "window:@2", "window:@3"])
    }

    func testEverySourceIsAChipWithThePalettesOwnFirst() {
        let sessions = CommandPaletteConfig(name: "Sessions", triggers: [], sources: [.sessions, .windows])
        XCTAssertEqual(sessions.chips, [.sessions, .windows, .agents])
        let agents = CommandPaletteConfig(name: "Agents", triggers: [], sources: [.agents])
        XCTAssertEqual(agents.chips, [.agents, .sessions, .windows])
        XCTAssertEqual(CommandPaletteConfig.goTo.chips, [.agents, .sessions, .windows])
    }

    func testAgentsThatNeedYouComeFirstThenWorkingOnes() {
        let agents = [
            agent("%1", window: mux, status: .done),
            agent("%2", window: notes, status: .working),
            agent("%3", window: web, status: .failed),
            agent("%4", window: mux, status: .done, unread: true),
            agent("%5", window: notes, status: .blocked),
            agent("%6", window: web, status: nil),
        ]
        let results = PaletteSearch.results(sources: [.agents], query: "", catalog: catalog(agents: agents))
        XCTAssertEqual(ids(results), ["agent:%3", "agent:%4", "agent:%5", "agent:%2", "agent:%1", "agent:%6"])
    }

    func testAWindowWithAnAgentIsLeftOutOnlyBesideTheAgentsSource() {
        let agents = [agent("%1", window: web, status: .working)]
        let both = PaletteSearch.results(sources: [.agents, .windows], query: "w", catalog: catalog(agents: agents))
        XCTAssertFalse(ids(both).contains("window:@3"))
        let windowsOnly = PaletteSearch.results(sources: [.sessions, .windows], query: "w", catalog: catalog(agents: agents))
        XCTAssertTrue(ids(windowsOnly).contains("window:@3"))
    }

    func testOnATieARunningSessionComesBeforeAFolderThenTheMoreRecent() {
        let paths = [SessionPath(path: "/q/notes2"), SessionPath(path: "/q/note")]
        let results = PaletteSearch.results(sources: [.sessions], query: "note", catalog: catalog(paths: paths))
        XCTAssertEqual(ids(results).first, "session:$notes")
        XCTAssertEqual(Set(ids(results)), ["session:$notes", "path:/q/notes2", "path:/q/note"])
    }

    func testEveryWordMustMatch() {
        let results = PaletteSearch.results(sources: [.sessions], query: "mux zzz", catalog: catalog())
        XCTAssertEqual(results.count, 0)
        XCTAssertEqual(ids(PaletteSearch.results(sources: [.sessions], query: "mx", catalog: catalog())).first,
                       "session:$muxify")
    }
}
