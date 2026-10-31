import XCTest
@testable import SwitcherCore

final class ProfileHealthTests: XCTestCase {
    func testReportsRenamedProfile() {
        let warnings = ProfileHealth.warnings(
            used: ["Личное", "Работа", "Работа", "", ProfileMatcher.privateProfile], detected: ["Личное", "Работа 2"])
        XCTAssertEqual(warnings, [.missingProfile("Работа")])
    }

    func testNothingMissingWhenProfilesAreUnknown() {
        XCTAssertEqual(ProfileHealth.warnings(used: ["A", "B"], detected: []), [])
    }
}
