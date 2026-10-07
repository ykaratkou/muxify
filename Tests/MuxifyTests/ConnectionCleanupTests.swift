import XCTest

final class ConnectionCleanupTests: XCTestCase {
    private let waitTimeout: TimeInterval = 10

    @MainActor func testSlowRetirementDoesNotBlockUiAndKeepsCleanupOrder() async {
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
            // Only the test releases this gate. An independent timeout could
            // let cleanup finish before a slower CI runner checks its state.
            // Do not block main forever if retirement regresses onto the UI.
            if !Thread.isMainThread { release.wait() }
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
        await fulfillment(of: [retiring, responsive], timeout: waitTimeout)
        XCTAssertEqual(phases.values, ["retire"])
        release.signal()
        await fulfillment(of: [finished], timeout: waitTimeout)
        XCTAssertEqual(phases.values, ["retire", "close surface", "remove transport files", "completion", "ready to quit"])
    }

    @MainActor func testQuitWaitsForAnEnvironmentSwitchAlreadyCleaningUp() async {
        let cleanup = ConnectionCleanup()
        let releaseSwitch = DispatchSemaphore(value: 0)
        defer { releaseSwitch.signal() }
        let switching = expectation(description: "earlier Environment cleanup")
        let currentClosed = expectation(description: "current Environment closed")
        let finished = expectation(description: "all connections cleaned")
        var completions = 0
        var readyToQuit = false
        cleanup.run(retire: {
            XCTAssertFalse(Thread.isMainThread)
            switching.fulfill()
            if !Thread.isMainThread { releaseSwitch.wait() }
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
        await fulfillment(of: [switching, currentClosed], timeout: waitTimeout)
        XCTAssertFalse(readyToQuit)
        releaseSwitch.signal()
        await fulfillment(of: [finished], timeout: waitTimeout)
    }

    @MainActor func testNoPendingCleanupStillCompletesAsynchronouslyOnMain() async {
        let cleanup = ConnectionCleanup()
        var returned = false
        let finished = expectation(description: "idle cleanup completion")
        cleanup.whenFinished {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(returned)
            finished.fulfill()
        }
        returned = true
        await fulfillment(of: [finished], timeout: waitTimeout)
    }

    private final class Phases {
        private let lock = NSLock()
        private var entries: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    }
}
