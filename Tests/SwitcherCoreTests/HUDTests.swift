import XCTest
@testable import SwitcherCore

final class HUDTests: XCTestCase {
    private func window(_ id: Int, _ title: String, tabs: Int = 1) -> SafariWindow {
        SafariWindow(id: id, title: title, tabCount: tabs, firstTabURL: "https://example.com")
    }

    private let profiles = ["Личное", "Работа", "Клиент"]

    func testProfileColumnsCurrentFirstNextSelected() {
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — Mail"), window(3, "Работа — Docs")]
        let state = HUDState.profiles(windows: windows, profiles: profiles)
        XCTAssertEqual(state.groups.map(\.profile), ["Работа", "Личное", "Клиент"])
        XCTAssertEqual(state.groups.map(\.windowCount), [2, 1, 0])
        XCTAssertEqual(state.items.map(\.target), [.window(id: 1), .window(id: 3), .window(id: 2), .profile("Клиент")])
        XCTAssertEqual(state.items.map(\.title), ["Jira", "Docs", "Mail", ""])
        XCTAssertEqual(state.selected?.target, .window(id: 2))
    }

    func testProfileColumnsWithoutCurrentSelectFirst() {
        let state = HUDState.profiles(windows: [window(9, "Частный доступ")], profiles: profiles)
        XCTAssertEqual(state.selected?.target, .profile("Личное"))
        XCTAssertEqual(state.groups.last?.profile, nil, "windows of no profile get their own column")
    }

    func testPrivateWindowsFormTheirOwnColumn() {
        let windows = [SafariWindow(id: 5, title: "Поиск", tabCount: 1, firstTabURL: "", isPrivate: true),
                       window(1, "Работа — Jira")]
        let state = HUDState.profiles(windows: windows, profiles: ["Работа", ProfileMatcher.privateProfile])
        XCTAssertEqual(state.groups.map(\.profile), [ProfileMatcher.privateProfile, "Работа"])
        XCTAssertEqual(state.items.first?.title, "Поиск")
        XCTAssertEqual(state.selected?.target, .window(id: 1))
    }

    func testStepsBetweenAndWithinProfiles() {
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — Mail"), window(3, "Работа — Docs"),
                       window(4, "Личное — News")]
        var state = HUDState.profiles(windows: windows, profiles: profiles)
        XCTAssertEqual(state.selected?.target, .window(id: 2))
        state.step(.down)
        XCTAssertEqual(state.selected?.target, .window(id: 4))
        state.step(.down)
        XCTAssertEqual(state.selected?.target, .window(id: 2), "wraps within the profile")
        state.step(.up)
        XCTAssertEqual(state.selected?.target, .window(id: 4))
        state.step(.next)
        XCTAssertEqual(state.selected?.target, .profile("Клиент"))
        state.step(.next)
        XCTAssertEqual(state.selected?.target, .window(id: 1), "wraps to the first profile, its front window")
        state.step(by: -2)
        XCTAssertEqual(state.selected?.target, .window(id: 2))
    }

    func testWindowsFrontToBackSecondSelected() {
        let windows = [window(1, "Работа — Jira", tabs: 3), window(2, "Личное — Mail")]
        let state = HUDState.windows(windows: windows, profiles: profiles)
        XCTAssertEqual(state.items.map(\.title), ["Jira", "Mail", ""])
        XCTAssertEqual(state.items.map(\.profile), ["Работа", "Личное", "Клиент"])
        XCTAssertEqual(state.selected?.target, .window(id: 2))
    }

    func testMoveWrapsBothWays() {
        var state = HUDState.windows(
            windows: [window(1, "Личное — A"), window(2, "Личное — B"), window(3, "Личное — C")], profiles: ["Личное"])
        state.move(by: 1)
        XCTAssertEqual(state.selection, 2)
        state.move(by: 1)
        XCTAssertEqual(state.selection, 0)
        state.step(.up)
        XCTAssertEqual(state.selection, 2)
    }

    func testWindowListTabs() {
        let windows = [window(1, "Работа — Jira", tabs: 3), window(2, "Личное — Mail", tabs: 2)]
        let tabs = [1: WindowTabs(titles: ["Jira", "Docs", "CI"], current: 0),
                    2: WindowTabs(titles: ["Mail", "News"], current: 1)]
        var state = HUDState.windows(windows: windows, profiles: profiles, tabs: tabs)
        XCTAssertEqual(state.selected?.target, .window(id: 2))
        XCTAssertEqual(state.selectedTab, 1, "starts on the window's current tab")
        state.step(.next)
        XCTAssertEqual(state.selectedTab, 0, "next / previous go through the tabs, wrapping")
        state.step(.up)
        XCTAssertEqual(state.selected?.target, .window(id: 1))
        XCTAssertEqual(state.selectedTab, 0)
        state.step(.previous)
        XCTAssertEqual(state.selectedTab, 2)
        state.step(by: 1)
        XCTAssertEqual(state.selected?.target, .window(id: 2), "the switch shortcut goes to the next window")
        state.select(windowID: 1, tab: 7)
        XCTAssertEqual(state.selectedTab, 2, "clamped to the tabs left")
        state.step(.down)
        state.step(.down)
        XCTAssertNil(state.selectedTab, "a new window row has no tabs")
    }

    func testWindowListOffersNewWindowsForProfilesWithout() {
        let state = HUDState.windows(windows: [window(1, "Личное — A")], profiles: profiles)
        XCTAssertEqual(state.items.map(\.target), [.window(id: 1), .profile("Работа"), .profile("Клиент")])
        XCTAssertEqual(state.selected?.target, .profile("Работа"), "with one window, the next profile's new window")
        XCTAssertEqual(HUDState.windows(windows: [], profiles: profiles).selected?.target, .profile("Личное"))
        XCTAssertNil(HUDState.windows(windows: [], profiles: []).selected)
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

    func testBackPressBeforeHUDSelectsBackwards() {
        var session = HUDKeySession(delay: 0.5)
        XCTAssertEqual(session.pressBack(at: 0), .none, "Shift alone doesn't start a session")
        _ = session.press(at: 0)
        XCTAssertEqual(session.pressBack(at: 0.1), .show(extraPresses: -1))
        XCTAssertEqual(session.pressBack(at: 0.2), .moveSelection(-1))
    }

    func testZeroDelayShowsOnFirstPress() {
        var session = HUDKeySession(delay: 0)
        XCTAssertEqual(session.press(at: 0), .show(extraPresses: 0))
        session.reset()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.tick(modifiersHeld: false, at: 1), .none)
    }
}
