import XCTest
import XPC
@testable import MuxifySimulatorServer

final class SimulatorDisplayReportTests: XCTestCase {
    func testIOS265LegacyDisplayReportWithInactiveExternalDisplays() throws {
        let report = try DisplayReport.parse(makeReport(legacy: true))
        XCTAssertEqual(report.displays.count, 2)
        XCTAssertEqual(report.activeIntegrated?.uniqueID, "display:1")
        XCTAssertEqual(report.activeIntegrated?.currentRotation, 90)
        XCTAssertEqual(report.activeIntegrated?.pixelSize, CGSize(width: 1206, height: 2622))
        XCTAssertEqual(report.activeIntegrated?.displayID, 1)
    }

    func testNewerDisplayReportStillUsesPanelIdentityAndActivity() throws {
        let report = try DisplayReport.parse(makeReport(legacy: false))
        XCTAssertEqual(report.activeIntegrated?.uniqueID, "main-screen")
        XCTAssertEqual(report.activeIntegrated?.currentRotation, 90)
    }

    func testDuplicateIdentityIsRejected() {
        let report = makeReport(legacy: true)
        let records = xpc_dictionary_get_value(report, "displays")!
        let external = xpc_array_get_value(records, 1)
        xpc_dictionary_set_uint64(external, "displayId", 1)
        XCTAssertThrowsError(try DisplayReport.parse(report))
    }

    func testMissingNewSchemaIdentityDoesNotFallBackToLegacyIdentity() {
        let report = makeReport(legacy: false)
        let records = xpc_dictionary_get_value(report, "displays")!
        xpc_dictionary_set_value(xpc_array_get_value(records, 0), "uniqueId", nil)
        XCTAssertThrowsError(try DisplayReport.parse(report))
    }

    private func makeReport(legacy: Bool) -> xpc_object_t {
        let output = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(output, "current", true)
        xpc_dictionary_set_string(output, "backlightState", "activeOn")
        let records = xpc_array_create(nil, 0)
        for index in 0..<2 {
            let record = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(record, "displayId", UInt64(index + 1))
            xpc_dictionary_set_bool(record, "primary", index == 0)
            xpc_dictionary_set_string(record, "currentOrientation", "rot90")
            if !legacy {
                xpc_dictionary_set_string(record, "uniqueId", index == 0 ? "main-screen" : "external-screen")
                xpc_dictionary_set_bool(record, "active", index == 0)
                xpc_dictionary_set_string(record, "backlightState", index == 0 ? "activeOn" : "off")
            }
            let type = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(type, index == 0 ? "integrated" : "external", xpc_dictionary_create(nil, nil, 0))
            xpc_dictionary_set_value(record, "type", type)
            let bounds = xpc_array_create(nil, 0)
            for corner in [CGPoint.zero, index == 0 ? CGPoint(x: 1206, y: 2622) : .zero] {
                let pair = xpc_array_create(nil, 0)
                xpc_array_append_value(pair, xpc_double_create(corner.x))
                xpc_array_append_value(pair, xpc_double_create(corner.y))
                xpc_array_append_value(bounds, pair)
            }
            xpc_dictionary_set_value(record, "bounds", bounds)
            xpc_array_append_value(records, record)
        }
        xpc_dictionary_set_value(output, "displays", records)
        return output
    }
}
