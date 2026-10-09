import AppKit
import SwiftUI
import XCTest

final class SidebarTypographyTests: XCTestCase {
    func testDefaultSystemFontsExactlyMatchExistingRoles() {
        let typography = SidebarTypography()
        let roles: [(SidebarTypography.Role, CGFloat, Font.Weight)] = [
            (.session, 14, .semibold), (.title, 12, .regular), (.section, 11, .semibold),
            (.location, 10.5, .regular), (.badge, 10, .medium),
        ]
        for (role, size, weight) in roles {
            XCTAssertEqual(typography.size(for: role), size)
            XCTAssertEqual(typography.font(for: role) { _, _, _ in
                XCTFail("The system font must not resolve an installed family")
                return nil
            }, Font.system(size: size, weight: weight))
        }
    }

    func testFractionalAndLargerBaseSizesScaleEveryTextRole() {
        for size in [12.5, 18.0, 24.0] {
            let typography = SidebarTypography(fontSize: size)
            for role in SidebarTypography.Role.allCases {
                let expected = CGFloat(size) * (role.defaultSize / 12)
                XCTAssertEqual(typography.size(for: role), expected, accuracy: 0.0001)
                XCTAssertEqual(typography.font(for: role), Font.system(size: expected, weight: role.weight))
            }
        }
    }

    func testExtremePositiveSizesKeepDerivedMetricsPositiveAndFinite() {
        for size in [Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
            for role in SidebarTypography.Role.allCases {
                let points = SidebarTypography(fontSize: size).size(for: role)
                XCTAssertGreaterThan(points, 0)
                XCTAssertTrue(points.isFinite)
            }
        }
    }

    func testFamilyLookupGetsRoleSizeAndWeightAndUsesClosestReturnedFace() {
        let typography = SidebarTypography(fontSize: 18, fontFamily: "Test Sans")
        for (role, expectedWeight) in [(SidebarTypography.Role.session, 8), (.title, 5), (.section, 8), (.location, 5), (.badge, 6)] {
            // The fake family has only one face: use its returned font rather
            // than switching to system fonts when an exact weight is absent.
            let closest = NSFont.systemFont(ofSize: typography.size(for: role), weight: .regular)
            var calls = 0
            let font = typography.font(for: role) { family, weight, size in
                calls += 1
                XCTAssertEqual(family, "Test Sans")
                XCTAssertEqual(weight, expectedWeight)
                XCTAssertEqual(size, typography.size(for: role))
                return closest
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(font, Font(closest))
        }
    }

    func testFamilyDisappearingAfterConfigReadStillRendersSystemText() {
        let typography = SidebarTypography(fontSize: 18, fontFamily: "Removed Font")
        for role in SidebarTypography.Role.allCases {
            XCTAssertEqual(typography.font(for: role) { _, _, _ in nil },
                           Font.system(size: typography.size(for: role), weight: role.weight))
        }
    }

    func testFamilyNormalizationUsesOnlyInstalledFamilyNames() {
        let families = { ["Test Sans", "Test Mono"] }
        XCTAssertEqual(SidebarTypography.canonicalFamily("  TEST sans  ", families: families), "Test Sans")
        XCTAssertEqual(SidebarTypography.canonicalFamily(" System ") {
            XCTFail("The system font must not require a font catalogue")
            return []
        }, "system")
        for invalid in ["", "   ", "Test\nSans", "Missing", "TestSans-Regular", "/fonts/Test.ttf"] {
            XCTAssertNil(SidebarTypography.canonicalFamily(invalid, families: families))
        }
    }

    @MainActor func testNativeFamilyLookupSupportsEveryTextWeight() throws {
        let family = try XCTUnwrap(SidebarTypography.fontFamilies.first { family in
            SidebarTypography.lookup(family: family, weight: 5, size: 12) != nil
        })
        for role in SidebarTypography.Role.allCases {
            let font = try XCTUnwrap(SidebarTypography.lookup(family: family, weight: role.familyWeight, size: role.defaultSize))
            XCTAssertEqual(font.familyName, family)
            XCTAssertEqual(font.pointSize, role.defaultSize)
        }
    }

    func testEnvironmentDefaultsAreCurrentSidebarTypography() {
        XCTAssertEqual(EnvironmentValues().sidebarTypography, SidebarTypography())
    }
}
