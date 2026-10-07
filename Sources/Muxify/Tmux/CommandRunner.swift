import Foundation
import Darwin

struct CommandInvocation: Equatable {
    let executable: String
    let arguments: [String]

    var commandLine: String { ([executable] + arguments).map(Tmux.shellQuote).joined(separator: " ") }
}

/// Owns finite subprocesses for one connection. Both pipes are drained in
/// parallel; cancellation and deadlines cannot strand the mutation queue.
final class CommandRunner {
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private var cancelled = false

    func run(_ invocation: CommandInvocation, timeout: TimeInterval = 10, environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        // On macOS, explicitly assigning nil clears the child environment.
        // Leave the property untouched to inherit AppEnvironment's locale,
        // PATH, SSH_AUTH_SOCK and other process-level fixes.
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        guard !cancelled else { lock.unlock(); throw TmuxError.cancelled }
        do { try process.run() } catch { lock.unlock(); throw error }
        processes[process.processIdentifier] = process
        lock.unlock()
        defer {
            lock.lock()
            processes[process.processIdentifier] = nil
            lock.unlock()
        }

        let output = CollectedData()
        let errors = CollectedData()
        let readers = DispatchGroup()
        for (pipe, result) in [(stdout, output), (stderr, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                result.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
        }
        let expired = CollectedData()
        let deadline = DispatchWorkItem {
            expired.set(Data([1]))
            Self.terminate(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()

        // A descendant could retain a pipe even after its parent exits.
        let drained = readers.wait(timeout: .now() + 1) == .success
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        if !expired.value.isEmpty || !drained { throw TmuxError.timedOut }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw TmuxError.cancelled }
        guard process.terminationStatus == 0 else {
            throw TmuxError.failed(
                status: process.terminationStatus,
                stderr: String(decoding: errors.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output.value, as: UTF8.self)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = Array(processes.values)
        lock.unlock()
        running.forEach(Self.terminate)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private final class CollectedData {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    }
}
