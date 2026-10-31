import XCTest
@testable import SwitcherCore

final class WindowGroupsTests: XCTestCase {
    func testGroupsByProfileInProfileOrder() {
        func window(_ id: Int, _ title: String) -> SafariWindow {
            SafariWindow(id: id, title: title, tabCount: 1, firstTabURL: "https://example.com")
        }
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — Mail"), window(3, "Работа — Docs"), window(4, "Частный")]
        let groups = WindowGroups.make(windows: windows, profiles: ["Личное", "Работа", "Клиент"])
        XCTAssertEqual(groups.map(\.profile), ["Личное", "Работа", "Клиент", nil])
        XCTAssertEqual(groups.map { $0.windows.map(\.id) }, [[2], [1, 3], [], [4]])
    }
}
