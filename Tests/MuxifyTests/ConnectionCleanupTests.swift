import XCTest

final class ConnectionCleanupTests: XCTestCase {
    @MainActor func testSlowRetirementDoesNotBlockUiAndKeepsCleanupOrder() {
        let cleanup = ConnectionCleanup()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let retiring = expectation(description: "background retirement started")
        let responsive = expectation(description: "main queue remains responsive")
        let finished = expectation(description: "cleanup finished")
        let phases = Phases()
        cleanup.run(retire: {
            XCTAssertFalse(Thread.isMainThread)
            phases.append("retire")
            retiring.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }, closeSurface: {
            XCTAssertTrue(Thread.isMainThread)
            phases.append("close surface")
        }, cleanup: {
            XCTAssertFalse(Thread.isMainThread)
            phases.append("remove transport files")
        }, completion: {
            XCTAssertTrue(Thread.isMainThread)
            phases.append("completion")
        })
        cleanup.whenFinished {
            XCTAssertTrue(Thread.isMainThread)
            phases.append("ready to quit")
            finished.fulfill()
        }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [retiring, responsive], timeout: 2)
        XCTAssertEqual(phases.values, ["retire"])
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(phases.values, ["retire", "close surface", "remove transport files", "completion", "ready to quit"])
    }

    @MainActor func testQuitWaitsForAnEnvironmentSwitchAlreadyCleaningUp() {
        let cleanup = ConnectionCleanup()
        let releaseSwitch = DispatchSemaphore(value: 0)
        defer { releaseSwitch.signal() }
        let switching = expectation(description: "earlier Environment cleanup")
        let currentClosed = expectation(description: "current Environment closed")
        let finished = expectation(description: "all connections cleaned")
        var completions = 0
        var readyToQuit = false
        cleanup.run(retire: {
            switching.fulfill()
            XCTAssertEqual(releaseSwitch.wait(timeout: .now() + 3), .success)
        }, closeSurface: {}, cleanup: {}, completion: { completions += 1 })
        cleanup.run(retire: {}, closeSurface: {}, cleanup: {}, completion: {
            completions += 1
            currentClosed.fulfill()
        })
        cleanup.whenFinished {
            readyToQuit = true
            XCTAssertEqual(completions, 2)
            finished.fulfill()
        }
        wait(for: [switching, currentClosed], timeout: 2)
        XCTAssertFalse(readyToQuit)
        releaseSwitch.signal()
        wait(for: [finished], timeout: 2)
    }

    @MainActor func testNoPendingCleanupStillCompletesAsynchronouslyOnMain() {
        let cleanup = ConnectionCleanup()
        var returned = false
        let finished = expectation(description: "idle cleanup completion")
        cleanup.whenFinished {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(returned)
            finished.fulfill()
        }
        returned = true
        wait(for: [finished], timeout: 2)
    }

    private final class Phases {
        private let lock = NSLock()
        private var entries: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    }
}
