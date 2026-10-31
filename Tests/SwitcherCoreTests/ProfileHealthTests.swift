import XCTest
@testable import SwitcherCore

final class ProfileHealthTests: XCTestCase {
    func testReportsRenamedProfile() {
        let warnings = ProfileHealth.warnings(
            used: ["Личное", "Работа", "Работа", ""], detected: ["Личное", "Работа 2"],
            windowTitles: ["Личное — Mail"])
        XCTAssertEqual(warnings, [.missingProfile("Работа")])
    }

    func testNothingMissingWhenProfilesAreUnknown() {
        XCTAssertEqual(ProfileHealth.warnings(used: ["A", "B"], detected: [], windowTitles: []), [])
    }

    func testReportsTitlesWithoutProfiles() {
        let warnings = ProfileHealth.warnings(
            used: ["Личное"], detected: ["Личное"], windowTitles: ["Mail", "GitHub — Repo"])
        XCTAssertEqual(warnings, [.unrecognizedTitles])
        XCTAssertEqual(ProfileHealth.warnings(used: ["Личное"], detected: ["Личное"], windowTitles: ["Mail", "Личное — x"]), [])
    }
}
