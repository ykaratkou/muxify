import AppKit
import XCTest

final class AppDelegateTests: XCTestCase {
    @MainActor func testLaunchUrlsAreQueuedUntilWindowRoutingIsReadyAndDeliveredOnce() throws {
        let delegate = AppDelegate()
        let url = try XCTUnwrap(URL(string: "muxify://select?session=main"))
        delegate.application(NSApplication.shared, open: [url])
        var delivered: [URL] = []
        delegate.openURLs = { delivered += $0 }
        XCTAssertEqual(delivered, [url])
        delegate.openURLs = { delivered += $0 }
        XCTAssertEqual(delivered, [url])
        delegate.application(NSApplication.shared, open: [url])
        XCTAssertEqual(delivered, [url, url])
    }

    @MainActor func testQuitWithoutAWorkspaceCanTerminateImmediately() {
        let delegate = AppDelegate()
        XCTAssertEqual(delegate.requestTermination { XCTFail("No deferred reply is needed") }, .terminateNow)
    }

    @MainActor func testQuitDefersExitUntilCleanupAndCoalescesRepeatedRequests() {
        let delegate = AppDelegate()
        var finish: (() -> Void)?
        var starts = 0
        var replies = 0
        delegate.shutdown = { completion in starts += 1; finish = completion }
        let replied = expectation(description: "termination reply")
        XCTAssertEqual(delegate.requestTermination {
            XCTAssertTrue(Thread.isMainThread)
            replies += 1
            replied.fulfill()
        }, .terminateLater)
        XCTAssertEqual(delegate.requestTermination { XCTFail("Quit must only reply once") }, .terminateLater)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(replies, 0)
        finish?()
        finish?()
        wait(for: [replied], timeout: 2)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(delegate.requestTermination { XCTFail("Already finished") }, .terminateNow)
    }

    @MainActor func testImmediateCleanupCannotReplyBeforeTerminateLaterReturns() {
        let delegate = AppDelegate()
        delegate.shutdown = { $0() }
        var returned = false
        let replied = expectation(description: "deferred immediate reply")
        XCTAssertEqual(delegate.requestTermination {
            XCTAssertTrue(returned)
            replied.fulfill()
        }, .terminateLater)
        returned = true
        wait(for: [replied], timeout: 2)
    }

    @MainActor func testBackgroundCleanupRepliesOnTheMainThread() {
        let delegate = AppDelegate()
        delegate.shutdown = { completion in DispatchQueue.global().async { completion() } }
        let replied = expectation(description: "main-thread termination reply")
        XCTAssertEqual(delegate.requestTermination {
            XCTAssertTrue(Thread.isMainThread)
            replied.fulfill()
        }, .terminateLater)
        wait(for: [replied], timeout: 2)
    }
}
