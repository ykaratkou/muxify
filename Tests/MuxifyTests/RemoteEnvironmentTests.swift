import XCTest

final class RemoteEnvironmentTests: XCTestCase {
    private func load(_ text: String) throws -> Config {
        try Config.load(path: "/cfg/muxify/config.yaml") { _ in text }.get()
    }

    func testEntriesKeepFileOrderAndOptionalDefaults() throws {
        let config = try load("""
        remote_environments:
          - name: Macbook Home
            host: home.example.ts.net
            username: user
          - name: Linux
            host: 100.64.1.2
            username: dev
            port: 2222
            identity_file: keys/dev
        """)
        XCTAssertEqual(config.remoteEnvironments, [
            RemoteEnvironment(name: "Macbook Home", host: "home.example.ts.net", username: "user"),
            RemoteEnvironment(name: "Linux", host: "100.64.1.2", username: "dev", port: 2222,
                              identityFile: "/cfg/muxify/keys/dev"),
        ])
        XCTAssertEqual(config.problems, [])
    }

    func testIdentityPathExpandsLocalHomeAndNullOptionalsUseDefaults() throws {
        let config = try load("""
        remote_environments:
          - name: home
            host: "[::1]"
            username: user
            identity_file: ~/.ssh/id_ed25519
            port:
          - name: work
            host: work
            username: user
            identity_file: null
        """)
        XCTAssertEqual(config.remoteEnvironments[0].identityFile, NSHomeDirectory() + "/.ssh/id_ed25519")
        XCTAssertNil(config.remoteEnvironments[0].port)
        XCTAssertNil(config.remoteEnvironments[1].identityFile)
        XCTAssertEqual(config.problems, [])
    }

    func testInvalidEntriesAreSkippedWithoutLosingValidEntriesOrOtherSettings() throws {
        let config = try load("""
        remote_environments:
          - name: empty
            host: home
            username:
          - name: good
            host: home
            username: user
          - name: good
            host: other
            username: user
          - name: Local
            host: local
            username: user
          - name: invalid-port
            host: host
            username: user
            port: 65536
        ui:
          header_height: 28
        """)
        XCTAssertEqual(config.remoteEnvironments.map(\.name), ["good"])
        XCTAssertEqual(config.problems.count, 4)
        XCTAssertEqual(config.problems.map(\.line), [4, 8, 11, 17])
        XCTAssertEqual(config.headerHeight, 28)
    }

    func testListAndRequiredFieldsAreValidated() throws {
        XCTAssertEqual(try load("remote_environments: {}").remoteEnvironments, [])
        XCTAssertEqual(try load("remote_environments: {}").problems.count, 1)
        for fields in ["host: host\n    username: user", "name: host\n    username: user", "name: host\n    host: host"] {
            let config = try load("remote_environments:\n  - \(fields)")
            XCTAssertTrue(config.remoteEnvironments.isEmpty)
            XCTAssertEqual(config.problems.count, 1)
        }
        for value in ["0", "-1", "65536", "1.5", "false", "'22'", "[22]"] {
            let config = try load("remote_environments:\n  - name: host\n    host: host\n    username: user\n    port: \(value)")
            XCTAssertTrue(config.remoteEnvironments.isEmpty, value)
            XCTAssertEqual(config.problems.count, 1, value)
        }
    }

    func testHostsAndUsernamesCannotInjectSshOptionsOrContainWhitespace() throws {
        for (key, value) in [("host", "-oProxyCommand=bad"), ("host", "bad host"), ("username", "-user"), ("username", "two users")] {
            let host = key == "host" ? value : "host"
            let user = key == "username" ? value : "user"
            let config = try load("remote_environments:\n  - name: test\n    host: '\(host)'\n    username: '\(user)'")
            XCTAssertTrue(config.remoteEnvironments.isEmpty)
            XCTAssertEqual(config.problems.count, 1)
        }
    }

    func testLiveReloadRetainsLastGoodConfigOnSyntaxError() throws {
        var loaded = LoadedConfig()
        let text = "remote_environments:\n  - name: home\n    host: host\n    username: user"
        loaded.update(with: Config.load(path: "/config") { _ in text })
        XCTAssertEqual(loaded.config.remoteEnvironments.count, 1)
        loaded.update(with: Config.load(path: "/config") { _ in "remote_environments: [" })
        XCTAssertEqual(loaded.config.remoteEnvironments.count, 1)
        XCTAssertEqual(loaded.problems.count, 1)
        loaded.update(with: Config.load(path: "/config") { _ in "remote_environments: []" })
        XCTAssertTrue(loaded.config.remoteEnvironments.isEmpty)
    }

    func testControlCharactersCannotReachTheHeaderOrProcessArguments() throws {
        for (key, value) in [("name", "bad\\nname"), ("identity_file", "bad\\0path")] {
            let name = key == "name" ? "\"\(value)\"" : "home"
            let identity = key == "identity_file" ? "\n    identity_file: \"\(value)\"" : ""
            let config = try load("remote_environments:\n  - name: \(name)\n    host: home\n    username: user\(identity)")
            XCTAssertTrue(config.remoteEnvironments.isEmpty)
            XCTAssertEqual(config.problems.count, 1)
        }
    }

    func testAgentForwardingIsEnabledByDefaultAndCanBeDisabled() throws {
        for (setting, expected) in [("", true), ("true", true), ("false", false), ("null", true)] {
            let line = setting.isEmpty ? "" : "\n    forward_agent: \(setting)"
            let config = try load("remote_environments:\n  - name: home\n    host: home\n    username: user\(line)")
            XCTAssertEqual(config.remoteEnvironments.first?.forwardAgent, expected)
            XCTAssertEqual(config.problems, [])
        }
        for value in ["'false'", "0", "[false]", "no-thanks"] {
            let config = try load("remote_environments:\n  - name: home\n    host: home\n    username: user\n    forward_agent: \(value)")
            XCTAssertTrue(config.remoteEnvironments.isEmpty, value)
            XCTAssertEqual(config.problems.count, 1, value)
        }
    }
}
