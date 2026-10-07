import Foundation
import Darwin

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessRunner {
    /// Cancelling a wait terminates only the simctl helper, never the Device it booted.
    static func runAsync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                try run(executable, arguments, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 30,
        cancellation: ProcessCancellation = ProcessCancellation()
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try cancellation.start(process)
        // Drain both pipes concurrently; a full stderr pipe must not deadlock stdout.
        let captured = CapturedOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            captured.store(output.fileHandleForReading.readDataToEndOfFile(), isError: false)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            captured.store(error.fileHandleForReading.readDataToEndOfFile(), isError: true)
            readers.leave()
        }
        let deadline = DispatchTime.now() + timeout
        var finished = false
        while !cancellation.isCancelled, DispatchTime.now() < deadline {
            if exited.wait(timeout: min(.now() + .milliseconds(25), deadline)) == .success {
                finished = true
                break
            }
        }
        if !finished {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            if cancellation.isCancelled { throw CancellationError() }
            throw CoreSimulatorError.privateCall(symbol: executable, message: "timed out after \(Int(timeout)) seconds")
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard readers.wait(timeout: .now() + 2) == .success else {
            throw CoreSimulatorError.privateCall(symbol: executable, message: "output pipes did not close")
        }
        let (outputData, errorData) = captured.read()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func store(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { error = data } else { output = data }
    }

    func read() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (output, error)
    }
}
