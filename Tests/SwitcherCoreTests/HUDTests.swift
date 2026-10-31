import XCTest
@testable import SwitcherCore

final class HUDTests: XCTestCase {
    private func window(_ id: Int, _ title: String, tabs: Int = 1) -> SafariWindow {
        SafariWindow(id: id, title: title, tabCount: tabs, firstTabURL: "https://example.com")
    }

    private let profiles = ["Личное", "Работа", "Клиент"]

    func testProfilesCurrentFirstNextSelected() {
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — Mail"), window(3, "Работа — Docs")]
        let state = HUDState.profiles(windows: windows, profiles: profiles)
        XCTAssertEqual(state.items.map(\.title), ["Работа", "Личное", "Клиент"])
        XCTAssertEqual(state.items.map(\.count), [2, 1, 0])
        XCTAssertEqual(state.selected?.target, .profile("Личное"))
    }

    func testProfilesWithoutCurrentSelectsFirst() {
        let state = HUDState.profiles(windows: [window(9, "Частный доступ")], profiles: profiles)
        XCTAssertEqual(state.selected?.target, .profile("Личное"))
    }

    func testWindowsFrontToBackSecondSelected() {
        let windows = [window(1, "Работа — Jira", tabs: 3), window(2, "Личное — Mail")]
        let state = HUDState.windows(windows: windows, profiles: profiles)
        XCTAssertEqual(state.items.map(\.title), ["Jira", "Mail"])
        XCTAssertEqual(state.items.map(\.profile), ["Работа", "Личное"])
        XCTAssertEqual(state.selected?.target, .window(id: 2))
    }

    func testMoveWrapsBothWays() {
        var state = HUDState.profiles(windows: [window(1, "Личное — A")], profiles: profiles)
        state.move(by: 1)
        XCTAssertEqual(state.selection, 2)
        state.move(by: 1)
        XCTAssertEqual(state.selection, 0)
        state.move(by: -1)
        XCTAssertEqual(state.selection, 2)
    }

    func testSingleWindowSelectionClamped() {
        let state = HUDState.windows(windows: [window(1, "Личное — A")], profiles: profiles)
        XCTAssertEqual(state.selection, 0)
        XCTAssertNil(HUDState.windows(windows: [], profiles: profiles).selected)
    }
}

final class HUDKeySessionTests: XCTestCase {
    func testQuickReleaseSwitchesWithoutHUD() {
        var session = HUDKeySession(delay: 0.2)
        XCTAssertEqual(session.press(at: 0), .none)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.tick(modifiersHeld: true, at: 0.1), .none)
        XCTAssertEqual(session.tick(modifiersHeld: false, at: 0.15), .switchNow)
        XCTAssertFalse(session.isActive)
    }

    func testHoldingShowsHUDAndReleaseConfirms() {
        var session = HUDKeySession(delay: 0.2)
        _ = session.press(at: 0)
        XCTAssertEqual(session.tick(modifiersHeld: true, at: 0.25), .show(extraPresses: 0))
        XCTAssertEqual(session.press(at: 0.3), .moveSelection(1))
        XCTAssertEqual(session.tick(modifiersHeld: true, at: 0.4), .none)
        XCTAssertEqual(session.tick(modifiersHeld: false, at: 0.5), .confirm)
        XCTAssertEqual(session.phase, .idle)
    }

    func testSecondPressShowsHUDRightAway() {
        var session = HUDKeySession(delay: 0.5)
        _ = session.press(at: 0)
        XCTAssertEqual(session.press(at: 0.05), .show(extraPresses: 1))
    }

    func testZeroDelayShowsOnFirstPress() {
        var session = HUDKeySession(delay: 0)
        XCTAssertEqual(session.press(at: 0), .show(extraPresses: 0))
        session.reset()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.tick(modifiersHeld: false, at: 1), .none)
    }
}
