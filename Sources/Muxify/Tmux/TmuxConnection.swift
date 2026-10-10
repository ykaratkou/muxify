import Foundation

/// The tmux execution seam. Every operation captures this immutable target;
/// changing the active Environment never retargets work already in flight.
final class TmuxConnection {
    private let id = UUID()
    let remote: RemoteSSH?
    private let runner = CommandRunner()
    private let queue = DispatchQueue(label: "muxify.tmux.connection", qos: .userInitiated)
    private let lock = NSLock()
    private var retired = false

    init(environment: RemoteEnvironment?, sshExecutable: String = "/usr/bin/ssh") throws {
        remote = try environment.map { try RemoteSSH(environment: $0, sshExecutable: sshExecutable) }
    }

    var isRemote: Bool { remote != nil }

    func invocation(_ args: [String]) throws -> CommandInvocation {
        if let remote { return remote.command(args) }
        guard let binary = Tmux.binary else { throw TmuxError.notInstalled }
        return CommandInvocation(executable: binary, arguments: args)
    }

    func run(_ args: [String]) throws -> String {
        lock.lock()
        let stopped = retired
        lock.unlock()
        guard !stopped else { throw TmuxError.cancelled }
        return try runner.run(invocation(args))
    }

    func runAsync(_ args: [String], completion: ((Result<String, Error>) -> Void)? = nil) {
        queue.async {
            let result = Result { try self.run(args) }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
    }

    /// Runs a /bin/sh `script` on the Environment's machine: over the SSH
    /// master for a Remote Environment, else here. Off the tmux queue, so a
    /// slow script never holds up tmux commands.
    func runScriptAsync(_ script: String, arguments: [String] = [], timeout: TimeInterval = 20,
                        completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                self.lock.lock()
                let stopped = self.retired
                self.lock.unlock()
                guard !stopped else { throw TmuxError.cancelled }
                let invocation = self.remote?.script(script, arguments: arguments)
                    ?? CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments)
                return try self.runner.run(invocation, timeout: timeout)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func snapshot() throws -> TmuxSnapshot {
        guard let remote else {
            do { return stamped(try Tmux.readSnapshot(using: run)) }
            catch let error as TmuxError where error.indicatesNoSessions {
                return TmuxSnapshot(windows: [], clients: [], panes: [], lastWindowID: nil, serverRunning: !error.indicatesNoServer)
            }
        }
        guard (try? runner.run(remote.control("check"), timeout: 1)) != nil else { throw TmuxError.notReady }
        let marker = try run(["show-option", "-sqv", remote.markerOption])
            .trimmingCharacters(in: .newlines).components(separatedBy: Tmux.separator)
        guard marker.count == 4, let pid = Int(marker[0]), !marker[1].isEmpty else { throw TmuxError.notReady }
        var snapshot = try Tmux.readSnapshot(using: run)
        guard let client = snapshot.clients.first(where: { $0.pid == pid && $0.tty == marker[1] && !$0.isControl }) else {
            throw TmuxError.notReady
        }
        snapshot.ownClientTTY = client.tty
        snapshot.homeDirectory = marker[2]
        for index in snapshot.windows.indices {
            snapshot.windows[index].homeDirectory = marker[2]
            snapshot.windows[index].hostName = marker[3]
            snapshot.windows[index].isRemote = true
        }
        return stamped(snapshot)
    }

    private func stamped(_ value: TmuxSnapshot) -> TmuxSnapshot {
        var snapshot = value
        for index in snapshot.windows.indices {
            snapshot.windows[index].sourceID = "\(id.uuidString):\(snapshot.serverID ?? "")"
        }
        return snapshot
    }

    var closedSnapshot: TmuxSnapshot? { remote?.closedSnapshot.map(stamped) }

    func terminalCommand(_ args: [String], target: String? = nil, createSessionIfNeeded: Bool = true) throws -> String {
        if let remote { return remote.terminalCommand(target: target, createSessionIfNeeded: createSessionIfNeeded) }
        return try invocation(args).commandLine
    }

    /// Cancel old operations immediately. Flush only idempotent Browser state,
    /// then close our master (never the remote tmux server). Called off-main.
    func retire(flushing commands: [[String]] = []) {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        retired = true
        lock.unlock()
        runner.cancel()
        let finalRunner = CommandRunner()
        let masterAvailable = remote.map { (try? finalRunner.run($0.control("check"), timeout: 1)) != nil } ?? true
        if masterAvailable {
            var flush = commands
            if let remote { flush.append(["set-option", "-su", remote.markerOption]) }
            if !flush.isEmpty, let invocation = try? invocation(Array(flush.joined(separator: [";"]))) {
                _ = try? finalRunner.run(invocation, timeout: 2)
            }
        }
        if let remote { _ = try? finalRunner.run(remote.control("exit"), timeout: 1) }
    }

    func cleanup() { remote?.cleanup() }
}
