import Foundation
import Darwin

/// Hears about tmux changes as they happen through a control-mode client
/// (`tmux -C`), so the sidebar doesn't wait for the next poll when a Window is
/// switched, added, closed or renamed. The client only listens: it is
/// read-only, gets no pane output and doesn't count towards window sizes.
final class TmuxEvents {
    enum Event {
        /// A Session's current Window changed (select-window, prefix+n, …).
        case sessionWindowChanged(sessionID: String, windowID: String)
        /// Anything else that may change what the sidebar shows.
        case other
    }

    /// Called on the main thread.
    var onEvent: ((Event) -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var nextStart = Date.distantPast

    var isRunning: Bool { process?.isRunning == true }

    /// Attaches to `sessionID`. Notifications cover every Session, so which
    /// one doesn't matter.
    func start(sessionID: String, connection: TmuxConnection) {
        guard !isRunning, Date() >= nextStart,
              let invocation = try? connection.invocation(["-C", "attach-session", "-f", "read-only,no-output,ignore-size", "-t", sessionID])
        else { return }
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        // Control mode exits when its input closes, so holding the pipe keeps
        // it running, and it goes away with us even if we crash.
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let buffer = EventBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = buffer.receive(data)
            DispatchQueue.main.async {
                guard let self, let process, self.process === process else { return }
                events.forEach { self.onEvent?($0) }
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, self.process === process else { return }
                self.stop()
                self.nextStart = Date().addingTimeInterval(2)
            }
        }
        self.process = process
        self.input = input
        self.output = output
        do {
            try process.run()
        } catch {
            NSLog("muxify: tmux control client failed to start: \(error)")
            stop()
            return
        }
    }

    func stop() {
        let old = process
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        if let old, old.isRunning {
            old.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
    }

    private final class EventBuffer {
        private let lock = NSLock()
        private var data = Data()
        func receive(_ incoming: Data) -> [Event] {
            lock.lock()
            defer { lock.unlock() }
            data.append(incoming)
            var events: [Event] = []
            while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
                data.removeSubrange(data.startIndex...newline)
                if let event = TmuxEvents.event(from: line) { events.append(event) }
            }
            return events
        }
    }

    private static func event(from line: String) -> Event? {
        let words = line.split(separator: " ")
        guard let kind = words.first, kind.hasPrefix("%") else { return nil }
        switch kind {
        case "%begin", "%end", "%error", "%output", "%extended-output", "%exit":
            return nil
        case "%session-window-changed" where words.count >= 3:
            return .sessionWindowChanged(sessionID: String(words[1]), windowID: String(words[2]))
        default:
            return .other
        }
    }
}
