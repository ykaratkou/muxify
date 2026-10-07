import XCTest

final class EnvironmentBadgeTests: XCTestCase {
    func testLocalNeverShowsAnSshConnectionIndicator() {
        for connected in [false, true] {
            for hasError in [false, true] {
                let label = EnvironmentBadgeLabel(name: "Local", isRemote: false, isConnected: connected, hasConnectionError: hasError)
                XCTAssertEqual(label.indicator, .none)
            }
        }
    }

    func testConnectedRemoteHasNoWarningOrSpinner() {
        for hasError in [false, true] {
            let label = EnvironmentBadgeLabel(name: "Macbook Home", isRemote: true, isConnected: true, hasConnectionError: hasError)
            XCTAssertEqual(label.indicator, .none)
        }
    }

    func testRemoteKeepsItsIdentityWhileConnectingOrDisconnected() {
        for (hasError, expected) in [(false, EnvironmentBadgeLabel.Indicator.connecting), (true, .disconnected)] {
            let label = EnvironmentBadgeLabel(name: "Macbook Home", isRemote: true, isConnected: false, hasConnectionError: hasError)
            XCTAssertEqual(label.indicator, expected)
            XCTAssertTrue(label.isRemote)
            XCTAssertEqual(label.name, "Macbook Home")
        }
    }
}
