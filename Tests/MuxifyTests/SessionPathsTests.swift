import XCTest

final class SessionPathsTests: XCTestCase {
    private let s = Tmux.separator

    func testParseKeepsConfigOrderSortsFoldersAndPutsWorktreesAfterTheirRepository() {
        let output = """
        E
        D\(s)/p/zeta
        D\(s)/p/alpha
        W\(s)/w/alpha/fix
        W\(s)/w/alpha/feature
        D\(s)/p/Beta
        E
        D\(s)/home/.dotfiles
        E
        D\(s)/p/alpha
        garbage
        """
        XCTAssertEqual(SessionPaths.parse(output), [
            SessionPath(path: "/p/alpha"),
            SessionPath(path: "/w/alpha/feature", repository: "/p/alpha"),
            SessionPath(path: "/w/alpha/fix", repository: "/p/alpha"),
            SessionPath(path: "/p/Beta"),
            SessionPath(path: "/p/zeta"),
            SessionPath(path: "/home/.dotfiles"),
        ])
    }

    func testNamesFollowTmuxSessionizer() {
        XCTAssertEqual(SessionPath(path: "/home/.dotfiles").sessionName, "_dotfiles")
        XCTAssertEqual(SessionPath(path: "/p/my app").sessionName, "myapp")
        XCTAssertEqual(SessionPath(path: "/w/liveops_server/ek-1.2", repository: "/p/liveops_server").sessionName,
                       "liveops_server [ek-1_2]")
    }

    func testANameAnotherFolderHasGetsItsParentInFront() {
        let path = SessionPath(path: "/Users/me/work/foo")
        XCTAssertEqual(SessionPaths.newSessionName(for: path, taken: ["bar"]), "foo")
        XCTAssertEqual(SessionPaths.newSessionName(for: path, taken: ["foo"]), "work-foo")
        XCTAssertNil(SessionPaths.newSessionName(for: path, taken: ["foo", "work-foo"]))
    }

    func testASessionMatchesByTheFolderItStartedIn() {
        let path = SessionPath(path: "/Users/me/work/foo")
        XCTAssertTrue(SessionPaths.matches(path, sessionFolder: "/Users/me/work/foo/"))
        XCTAssertFalse(SessionPaths.matches(path, sessionFolder: "/Users/me/projects/foo"))
        XCTAssertFalse(SessionPaths.matches(path, sessionFolder: ""))
    }

    func testTheScriptFindsFoldersAndWorktreesAndSkipsHiddenAndMissingOnes() throws {
        let directory = try TestDirectory()
        // git prints real paths: /private/var, not /var.
        let home = String(cString: realpath(directory.url.path, nil))
        let fm = FileManager.default
        for folder in ["projects/app", "projects/lib/nested/deep", "projects/.cache", "projects/lib/.hidden", "dotfiles", "trees"] {
            try fm.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
        }
        let git = { (args: [String]) in
            _ = try CommandRunner().run(CommandInvocation(executable: "/usr/bin/env", arguments: ["git"] + args),
                                        environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                                                      "GIT_CONFIG_NOSYSTEM": "1"])
        }
        try git(["-C", "\(home)/projects/app", "init", "-q"])
        try git(["-C", "\(home)/projects/app", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"])
        try git(["-C", "\(home)/projects/app", "worktree", "add", "-q", "\(home)/trees/fix", "-b", "fix"])

        let roots = [
            SessionPathRoot(path: "~/projects/", depth: 2),
            SessionPathRoot(path: "~/dotfiles", depth: 0),
            SessionPathRoot(path: "~/missing", depth: 1),
            SessionPathRoot(path: "\(home)/projects/app", depth: 0),
        ]
        let output = try CommandRunner().run(
            CommandInvocation(executable: "/bin/sh", arguments: ["-c", SessionPaths.script, "muxify"] + SessionPaths.arguments(for: roots)),
            environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        )
        XCTAssertEqual(SessionPaths.parse(output).map { $0.path.replacingOccurrences(of: home, with: "~") }, [
            "~/projects/app", "~/trees/fix", "~/projects/lib", "~/projects/lib/nested", "~/dotfiles",
        ])
        XCTAssertEqual(SessionPaths.parse(output)[1].sessionName, "app [fix]")
    }

    func testRemoteConfigFileOutput() {
        XCTAssertEqual(RemoteConfigFile.parse("/h/.config/muxify/config.yaml\npresent\nui:\n  header_height: 30\n")?.text,
                       "ui:\n  header_height: 30\n")
        XCTAssertEqual(RemoteConfigFile.parse("/h/.config/muxify/config.yaml\npresent\n")?.text, "")
        let missing = RemoteConfigFile.parse("/h/.config/muxify/config.yaml\nmissing\n")
        XCTAssertEqual(missing?.path, "/h/.config/muxify/config.yaml")
        XCTAssertNil(missing?.text)
        XCTAssertNil(RemoteConfigFile.parse("Welcome!\n"))
    }
}
