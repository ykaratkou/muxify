import XCTest
@testable import MuxifySimulatorServer

final class SimulatorProcessTests: XCTestCase {
    func testCancellationInterruptsSubprocessWait() async throws {
        let task = Task { try await ProcessRunner.runAsync("/bin/sleep", ["10"]) }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testFullErrorPipeDoesNotBlockReadingStandardOutput() throws {
        let result = try ProcessRunner.run("/usr/bin/awk", [
            "BEGIN { for (i = 0; i < 20000; i++) print \"diagnostic\" > \"/dev/stderr\"; print \"done\" }"
        ], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "done\n")
        XCTAssertGreaterThan(result.standardError.utf8.count, 100_000)
    }

    func testUnresponsiveSubprocessIsBounded() {
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
