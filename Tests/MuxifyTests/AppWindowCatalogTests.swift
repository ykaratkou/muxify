import XCTest

final class AppWindowCatalogTests: XCTestCase {
    func testRemoteClicksReuseTheReservationBeforeItsWindowAppears() {
        var catalog = AppWindowCatalog()
        let local = catalog.newLocalWindow()
        catalog.focus(local.id)
        let remote = catalog.openEnvironment(named: "Home")
        XCTAssertEqual(catalog.openEnvironment(named: "Home").id, remote.id)
        XCTAssertEqual(catalog.requests.count, 2)
        XCTAssertNil(catalog.requests.first { $0.id == local.id }?.environmentName)
        XCTAssertEqual(catalog.focusedID, local.id)
    }

    func testNewAppWindowAlwaysCreatesANewLocalIdentity() {
        var catalog = AppWindowCatalog()
        let remote = catalog.openEnvironment(named: "Home")
        catalog.focus(remote.id)
        let first = catalog.newLocalWindow()
        let second = catalog.newLocalWindow()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(first.environmentName)
        XCTAssertNil(second.environmentName)
        XCTAssertEqual(catalog.requests.count, 3)
    }

    func testSelectingLocalReusesTheFocusedLocalWindow() {
        var catalog = AppWindowCatalog()
        let first = catalog.newLocalWindow()
        _ = catalog.newLocalWindow()
        catalog.focus(first.id)
        XCTAssertEqual(catalog.openEnvironment(named: nil).id, first.id)
        XCTAssertEqual(catalog.requests.count, 2)
    }

    func testClosedRemoteIsNotReused() {
        var catalog = AppWindowCatalog()
        let remote = catalog.openEnvironment(named: "Home")
        catalog.focus(remote.id)
        catalog.close(remote.id)
        XCTAssertNil(catalog.focusedID)
        XCTAssertNotEqual(catalog.openEnvironment(named: "Home").id, remote.id)
    }

    func testConfigFallbackUpdatesDestinationWithoutChangingSceneIdentity() {
        var catalog = AppWindowCatalog()
        let remote = catalog.openEnvironment(named: "Home")
        catalog.updateEnvironment(remote.id, name: nil)
        XCTAssertEqual(catalog.openEnvironment(named: nil).id, remote.id)
        XCTAssertNotEqual(catalog.openEnvironment(named: "Home").id, remote.id)
    }

    func testRegistrationIsIdempotentAndUnknownFocusIsIgnored() {
        var catalog = AppWindowCatalog()
        let local = catalog.newLocalWindow()
        catalog.register(local)
        catalog.focus(local.id)
        catalog.focus(UUID())
        XCTAssertEqual(catalog.requests, [local])
        XCTAssertEqual(catalog.focusedID, local.id)
    }

    func testSceneRequestRoundTripsAndHashesOnlyItsStableIdentity() throws {
        let request = AppWindowRequest(environmentName: "Home")
        let restored = try JSONDecoder().decode(AppWindowRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.id, request.id)
        XCTAssertEqual(restored.environmentName, request.environmentName)
        XCTAssertEqual(Set([request, AppWindowRequest(id: request.id)]).count, 1)
    }
}
