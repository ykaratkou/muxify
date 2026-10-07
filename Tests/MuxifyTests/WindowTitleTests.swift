import XCTest

final class WindowTitleTests: XCTestCase {
    private func window(title: String, name: String = "fish", remote: Bool = true,
                        host: String = "Yauhens-MacBook-Air.local") -> TmuxWindow {
        TmuxWindow(id: "@0", sessionID: "$0", sessionName: "main", index: 0, name: name,
                   paneTitle: title, path: "/Users/user/projects/muxify-mobile", command: "fish",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], homeDirectory: "/Users/user",
                   hostName: host, isRemote: remote)
    }

    func testRemoteFishHostPrefixIsHiddenOnlyInTheDisplayTitle() {
        for prefix in ["[Yauhens-Ma]", "[Yauhens-MacBook-Air]", "[Yauhens-MacBook-Air.local]"] {
            let title = "\(prefix) ~/p/muxify-mobile"
            let value = window(title: title)
            XCTAssertEqual(value.displayTitle, "~/p/muxify-mobile")
            XCTAssertEqual(value.paneTitle, title)
            XCTAssertEqual(value.name, "fish")
        }
        XCTAssertEqual(window(title: "[mini] ~/p/app", host: "mini.local").displayTitle, "~/p/app")
        XCTAssertEqual(window(title: "[mini.local] ~/p/app", host: "mini.local").displayTitle, "~/p/app")
    }

    func testLocalAndUnrelatedBracketedTitlesArePreserved() {
        let localTitle = "[Yauhens-Ma] ~/p/muxify-mobile"
        XCTAssertEqual(window(title: localTitle, remote: false).displayTitle, localTitle)
        for title in ["[other-host] ~/p/app", "[TODO] important task", "[Yauhens-Ma]without-space", "OC | Repository rename"] {
            XCTAssertEqual(window(title: title).displayTitle, title)
        }
    }

    func testHostOnlyTitlesFallBackAndAgentTitlesStillLoseTheirGlyph() {
        for title in ["", "Yauhens-MacBook-Air.local", "Yauhens-MacBook-Air", "[Yauhens-Ma]"] {
            XCTAssertEqual(window(title: title).displayTitle, "~/p/muxify-mobile")
            XCTAssertEqual(window(title: title, name: "custom name").displayTitle, "custom name")
        }
        XCTAssertEqual(window(title: "✳ Conversation title").displayTitle, "Conversation title")
        XCTAssertEqual(window(title: "[Yauhens-Ma] ✳ Conversation title").displayTitle, "Conversation title")
    }
}
