import XCTest

final class RemoteSSHTests: XCTestCase {
    private func remote(in directory: TestDirectory) throws -> RemoteSSH {
        try RemoteSSH(environment: RemoteEnvironment(name: "Home", host: "home.example.ts.net", username: "user",
                                                    port: 2222, identityFile: "/keys/space and 'quote'"),
                      temporaryDirectory: directory.url)
    }

    func testSshOptionsReadConfigRemainKeyOnlyAndMasterOnly() throws {
        let directory = try TestDirectory()
        let ssh = try remote(in: directory)
        let invocation = ssh.command(["rename-window", "-t", "@0", "quotes ' ; $() 😃"])
        let args = invocation.arguments
        XCTAssertEqual(invocation.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(args.prefix(3)), ["-l", "user", "-A"])
        XCTAssertFalse(args.contains("-F"))
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-p")) + 1], "2222")
        for option in ["BatchMode=yes", "ProxyCommand=/usr/bin/false", "PasswordAuthentication=no",
                       "KbdInteractiveAuthentication=no", "PreferredAuthentications=publickey",
                       "ClearAllForwardings=yes", "StrictHostKeyChecking=ask"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertTrue(args.contains("/keys/space and 'quote'"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertEqual(args[args.count - 2], "home.example.ts.net")
        XCTAssertTrue(args.last!.contains(Tmux.shellQuote(Tmux.shellQuote("quotes ' ; $() 😃")).dropFirst().dropLast()))
    }

    func testAgentForwardingCanBeDisabledOnEverySshLane() throws {
        let directory = try TestDirectory()
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "Home", host: "home", username: "user", forwardAgent: false),
                                temporaryDirectory: directory.url)
        for invocation in [ssh.attachmentInvocation(), ssh.command(["list-sessions"]), ssh.control("check")] {
            XCTAssertTrue(invocation.arguments.contains("-a"))
            XCTAssertFalse(invocation.arguments.contains("-A"))
            XCTAssertFalse(invocation.arguments.contains("-p"))
            XCTAssertTrue(invocation.arguments.contains("ForkAfterAuthentication=no"))
        }
    }

    func testSshConfigSuppliesAliasPortAndIdentityAgentWhileMuxifyOwnsConnection() throws {
        let directory = try TestDirectory()
        let config = directory.url.appendingPathComponent("config")
        let agent = directory.url.appendingPathComponent("agent.sock").path
        try """
        Host fixture
            HostName fixture.example
            User ssh-config-user
            Port 2201
            IdentityAgent \(agent)
            ForwardAgent no
            ProxyJump jump.example
            ControlMaster auto
            ControlPersist yes
            ControlPath /tmp/shared-ssh-socket
            ForkAfterAuthentication yes
            RemoteCommand echo unwanted-shell
        """.write(to: config, atomically: true, encoding: .utf8)
        func resolved(_ environment: RemoteEnvironment) throws -> [String: String] {
            let ssh = try RemoteSSH(environment: environment, temporaryDirectory: directory.url)
            // A fixture config instead of modifying the user's ~/.ssh/config.
            let owner = ssh.attachmentInvocation()
            let output = try CommandRunner().run(CommandInvocation(
                executable: owner.executable, arguments: ["-G", "-F", config.path] + owner.arguments
            ))
            let values = Dictionary(output.split(separator: "\n").compactMap { line -> (String, String)? in
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { return nil }
                return (String(fields[0]), String(fields[1]))
            }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(values["hostname"], "fixture.example")
            XCTAssertEqual(values["user"], environment.username)
            XCTAssertEqual(values["identityagent"], agent)
            XCTAssertEqual(values["proxyjump"], "jump.example")
            XCTAssertEqual(values["controlpath"], ssh.socketPath)
            XCTAssertEqual(values["controlpersist"], "no")
            XCTAssertEqual(values["forkafterauthentication"], "no")
            XCTAssertNil(values["remotecommand"])
            return values
        }
        let defaults = try resolved(RemoteEnvironment(name: "fixture", host: "fixture", username: "user"))
        XCTAssertEqual(defaults["port"], "2201")
        XCTAssertEqual(defaults["forwardagent"], "yes")
        let overridden = try resolved(RemoteEnvironment(name: "fixture", host: "fixture", username: "user", port: 2222, forwardAgent: false))
        XCTAssertEqual(overridden["port"], "2222")
        XCTAssertEqual(overridden["forwardagent"], "no")
    }

    func testEachConnectionHasAPrivateSocketAndMarker() throws {
        let directory = try TestDirectory()
        let first = try remote(in: directory)
        let second = try remote(in: directory)
        XCTAssertNotEqual(first.socketPath, second.socketPath)
        XCTAssertNotEqual(first.markerOption, second.markerOption)
        XCTAssertLessThan(first.socketPath.utf8.count, 104)
        let permissions = try FileManager.default.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    func testTerminalAndRemoteBootstrapScriptsParseWithoutExecutingSsh() throws {
        let directory = try TestDirectory()
        let ssh = try remote(in: directory)
        let invocation = ssh.terminalInvocation(target: "$0:@0")
        XCTAssertEqual(invocation.executable, "/bin/bash")
        let script = invocation.arguments[1]
        XCTAssertTrue(script.contains("SSH_ASKPASS_REQUIRE=never"))
        XCTAssertTrue(script.contains("TERM=\"${TERM:-xterm-256color}\""))
        XCTAssertTrue(script.contains("ControlPersist=no"))
        XCTAssertNoThrow(try CommandRunner().run(CommandInvocation(executable: "/bin/bash", arguments: ["-n", "-c", script])))
        XCTAssertNoThrow(try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-n", "-c", ssh.bootstrap()])))
        let bootstrap = ssh.bootstrap()
        XCTAssertTrue(bootstrap.contains("${SSH_TTY:-$(tty)}"))
        XCTAssertTrue(bootstrap.contains("$$"))
        XCTAssertTrue(bootstrap.contains("-d -s main -c \"$HOME\""))
        XCTAssertTrue(bootstrap.contains("tmux 3.2 or newer"))
        let marker = try XCTUnwrap(bootstrap.range(of: "set-option -sq"))
        let attach = try XCTUnwrap(bootstrap.range(of: "exec tmux -u -T RGB attach-session"))
        XCTAssertLessThan(marker.lowerBound, attach.lowerBound)
    }

    func testTerminalPreservesGhosttyTermAndDefaultsOnlyWhenMissing() throws {
        let directory = try TestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let fake = directory.url.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf '%s' \"$TERM\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "fake", host: "unused", username: "unused"),
                                temporaryDirectory: directory.url, sshExecutable: fake.path)
        for term in ["xterm-ghostty", "xterm-256color", ""] {
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = term
            XCTAssertEqual(try CommandRunner().run(ssh.terminalInvocation(), environment: environment),
                           term.isEmpty ? "xterm-256color" : term)
        }
    }

    func testBootstrapKeepsSupportedTermAndFallbackStillAdvertisesTrueColor() throws {
        let directory = try TestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let tmux = directory.url.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        if [ "$2" = -V ]; then printf 'tmux 3.2\\n'; fi
        if [ "$2" = -T ]; then printf '%s|%s|%s' "$TERM" "$COLORTERM" "$*"; fi

        """.write(to: tmux, atomically: true, encoding: .utf8)
        let infocmp = directory.url.appendingPathComponent("infocmp")
        try "#!/bin/sh\n[ \"$1\" = xterm-ghostty ]\n".write(to: infocmp, atomically: true, encoding: .utf8)
        for file in [tmux, infocmp] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let ssh = try remote(in: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.url.path + ":/usr/bin:/bin"
        environment["SSH_TTY"] = "/dev/fake"
        for term in ["xterm-ghostty", "missing-terminfo", ""] {
            environment["TERM"] = term
            let expectedTerm = term == "xterm-ghostty" ? term : "xterm-256color"
            for target in [nil, "$0:@0"] as [String?] {
                let output = try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", ssh.bootstrap(target: target)]),
                                                     environment: environment)
                XCTAssertEqual(output, "\(expectedTerm)|truecolor|-u -T RGB attach-session" + (target.map { " -t \($0)" } ?? ""))
            }
        }
    }

    func testMutationChecksOwnMarkerAndClientPid() throws {
        let directory = try TestDirectory()
        let ssh = try remote(in: directory)
        let command = ssh.command(["switch-client", "-c", "/dev/pts/12", "-t", "$0:@0"]).arguments.last!
        XCTAssertTrue(command.contains("#{client_pid}"))
        XCTAssertTrue(command.contains(ssh.markerOption))
        XCTAssertTrue(command.contains("remote tmux client changed"))
        XCTAssertFalse(ssh.command(["show-option", "-sqv", ssh.markerOption]).arguments.last!.contains("attachment is no longer available"))
    }

    func testReconnectDistinguishesDetachAndAuthenticationOrSetupFailure() throws {
        let directory = try TestDirectory()
        let ssh = try remote(in: directory)
        for (status, error, expected) in [
            (0, "", false), (255, "Connection reset by peer", true),
            (255, "Permission denied (publickey).", false),
            (255, "Host key verification failed.", false),
            (255, "", false),
            (255, "The authenticity of host home cannot be established.", false),
            (255, "Timeout, server home not responding.", true),
            (127, "Muxify: tmux was not found on the remote machine.", false),
            (2, "Muxify: remote tmux 3.2 or newer is required.", false),
        ] {
            try String(status).write(to: ssh.directory.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
            try error.write(to: ssh.directory.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
            XCTAssertEqual(ssh.shouldReconnect, expected, error)
        }
    }

    func testTerminalLoggerPreservesStdoutAndActualSshExitStatus() throws {
        let directory = try TestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let fake = directory.url.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf pane-output\nprintf 'diagnostic\\n' >&2\nexit 0\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let ssh = try RemoteSSH(environment: RemoteEnvironment(name: "fake", host: "unused", username: "unused"),
                                temporaryDirectory: directory.url, sshExecutable: fake.path)
        XCTAssertEqual(try CommandRunner().run(ssh.terminalInvocation()), "pane-output")
        XCTAssertEqual(ssh.exitStatus, 0)
        XCTAssertEqual(ssh.failureMessage, "diagnostic")
        try "#!/bin/sh\nprintf 'Connection reset by peer\\n' >&2\nexit 255\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertThrowsError(try CommandRunner().run(ssh.terminalInvocation()))
        XCTAssertEqual(ssh.exitStatus, 255)
        XCTAssertTrue(ssh.shouldReconnect)
    }
}
