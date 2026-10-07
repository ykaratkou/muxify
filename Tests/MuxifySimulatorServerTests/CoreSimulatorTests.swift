import XCTest
@testable import MuxifySimulatorServer

final class CoreSimulatorTests: XCTestCase {
    func testDeviceStatesUseKnownNumbersAndFallBackToStateStrings() {
        for (number, expected) in [(1, DeviceState.shutdown), (2, .booting), (3, .booted), (4, .shuttingDown)] {
            XCTAssertEqual(DeviceState.from(state: UInt(number), stateString: "Unknown"), expected)
        }
        XCTAssertEqual(DeviceState.from(state: 99, stateString: "Shutting Down"), .shuttingDown)
        XCTAssertEqual(DeviceState.from(state: 99, stateString: "Booted"), .booted)
        XCTAssertEqual(DeviceState.from(state: 99, stateString: "New state"), .unknown)
    }

    func testFourPhysicalTurnsRestoreOrientationAndNativeTouchCoordinates() {
        let orientations: [DeviceOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
        let points = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.3, y: 0.8),
                      CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.7, y: 0.2)]
        let workspaceValues: [UInt32] = [1, 4, 2, 3]
        for index in orientations.indices {
            let orientation = orientations[index]
            XCTAssertEqual(orientation.degrees, index * 90)
            XCTAssertEqual(orientation.rotatedRight, orientations[(index + 1) % 4])
            let point = orientation.nativePoint(CGPoint(x: 0.2, y: 0.3))
            XCTAssertEqual(point.x, points[index].x, accuracy: 0.0001)
            XCTAssertEqual(point.y, points[index].y, accuracy: 0.0001)
            XCTAssertEqual(orientation.gsEventValue, workspaceValues[index])
        }
    }

    func testBootWaitCannotBootOrTargetOtherDevices() {
        XCTAssertEqual(SimctlService.bootArguments(udid: deviceA), ["simctl", "boot", deviceA])
        XCTAssertEqual(SimctlService.shutdownArguments(udid: deviceA), ["simctl", "shutdown", deviceA])
        XCTAssertEqual(SimctlService.bootStatusArguments(udid: deviceA), ["simctl", "bootstatus", deviceA])
    }
}
