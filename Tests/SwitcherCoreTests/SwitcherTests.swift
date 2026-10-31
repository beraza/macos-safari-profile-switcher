import XCTest
@testable import SwitcherCore

final class SwitcherTests: XCTestCase {
    private let personal = "Личное"
    private let work = "Работа"

    private func window(_ id: Int, _ title: String, tabs: Int = 3, url: String = "https://example.com") -> SafariWindow {
        SafariWindow(id: id, title: title, tabCount: tabs, firstTabURL: url)
    }

    func testProfileMatching() {
        let profiles = [personal, work, "Работа 2"]
        XCTAssertEqual(ProfileMatcher.profile(ofTitle: "Личное — Начальная страница", among: profiles), personal)
        XCTAssertEqual(ProfileMatcher.profile(ofTitle: "Работа 2 — GitHub", among: profiles), "Работа 2")
        XCTAssertEqual(ProfileMatcher.profile(ofTitle: "Работа — Почта — Inbox", among: profiles), work)
        XCTAssertNil(ProfileMatcher.profile(ofTitle: "Личный кабинет — Банк", among: profiles))
    }

    func testEmptyStartPage() {
        XCTAssertTrue(window(1, "x", tabs: 1, url: "favorites://").isEmptyStartPage)
        XCTAssertTrue(window(1, "x", tabs: 1, url: "").isEmptyStartPage)
        XCTAssertFalse(window(1, "x", tabs: 2, url: "favorites://").isEmptyStartPage)
        XCTAssertFalse(window(1, "x", tabs: 1, url: "https://apple.com").isEmptyStartPage)
    }

    func testOpensSecondProfileWhenMissing() {
        let plan = Switcher.decide(windows: [window(1, "Личное — Google")], first: personal, second: work)
        XCTAssertEqual(plan, SwitchPlan(target: .openNew(profile: work), closeWindowID: nil, cycle: nil))
    }

    func testFocusesExistingWindowOfOtherProfile() {
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — YouTube"), window(3, "Личное — Mail")]
        let plan = Switcher.decide(windows: windows, first: personal, second: work)
        XCTAssertEqual(plan, SwitchPlan(
            target: .focus(windowID: 2), closeWindowID: nil, cycle: CycleState(profile: personal, visited: [2])))
    }

    func testCyclesThroughWindowsOfProfileThenSwitches() {
        let p1 = window(1, "Личное — A"), p2 = window(2, "Личное — B"), p3 = window(3, "Личное — C")
        let w4 = window(4, "Работа — Jira")

        let first = Switcher.decide(windows: [p1, p2, p3, w4], first: personal, second: work)
        XCTAssertEqual(first?.target, .focus(windowID: 2))

        // Focusing moves the window to the front; the rest keep their order.
        let second = Switcher.decide(windows: [p2, p1, p3, w4], first: personal, second: work, cycle: first?.cycle)
        XCTAssertEqual(second?.target, .focus(windowID: 3))

        let third = Switcher.decide(windows: [p3, p2, p1, w4], first: personal, second: work, cycle: second?.cycle)
        XCTAssertEqual(third, SwitchPlan(
            target: .focus(windowID: 4), closeWindowID: nil, cycle: CycleState(profile: work, visited: [4])))

        // Back to the most recent window of the first profile.
        let fourth = Switcher.decide(windows: [w4, p3, p2, p1], first: personal, second: work, cycle: third?.cycle)
        XCTAssertEqual(fourth?.target, .focus(windowID: 3))
    }

    func testManualWindowChangeStartsNewRound() {
        let p1 = window(1, "Личное — A"), p2 = window(2, "Личное — B"), p3 = window(3, "Личное — C")
        // Last shown was window 2, but the user clicked window 3.
        let plan = Switcher.decide(
            windows: [p3, p2, p1], first: personal, second: work,
            cycle: CycleState(profile: personal, visited: [1, 2]))
        XCTAssertEqual(plan?.target, .focus(windowID: 2))
        XCTAssertEqual(plan?.cycle, CycleState(profile: personal, visited: [3, 2]))
    }

    func testClosesEmptyStartPageWindowOfAnyProfile() {
        let fromPersonal = Switcher.decide(
            windows: [window(1, "Личное — Начальная страница", tabs: 1, url: "favorites://"), window(2, "Работа — Jira")],
            first: personal, second: work)
        XCTAssertEqual(fromPersonal, SwitchPlan(
            target: .focus(windowID: 2), closeWindowID: 1, cycle: CycleState(profile: work, visited: [2])))

        let fromWork = Switcher.decide(
            windows: [window(5, "Работа — Начальная страница", tabs: 1, url: "favorites://")],
            first: personal, second: work)
        XCTAssertEqual(fromWork, SwitchPlan(target: .openNew(profile: personal), closeWindowID: 5, cycle: nil))
    }

    func testKeepsEmptyStartPageWhenClosingDisabled() {
        let windows = [window(1, "Личное — Начальная страница", tabs: 1, url: "favorites://"), window(2, "Работа — Jira")]
        let plan = Switcher.decide(windows: windows, first: personal, second: work, closeEmpty: false)
        XCTAssertEqual(plan?.target, .focus(windowID: 2))
        XCTAssertNil(plan?.closeWindowID)
    }

    func testPageTitle() {
        XCTAssertEqual(ProfileMatcher.pageTitle(ofTitle: "Работа — Почта — Inbox", profile: work), "Почта — Inbox")
        XCTAssertEqual(ProfileMatcher.pageTitle(ofTitle: "Работа", profile: work), "")
        XCTAssertEqual(ProfileMatcher.pageTitle(ofTitle: "Без профиля", profile: nil), "Без профиля")
    }

    func testClosesEmptyStartPageWhileCyclingWithinProfile() {
        let windows = [window(1, "Личное — Начальная страница", tabs: 1, url: "favorites://"), window(2, "Личное — Mail")]
        let plan = Switcher.decide(windows: windows, first: personal, second: work)
        XCTAssertEqual(plan?.target, .focus(windowID: 2))
        XCTAssertEqual(plan?.closeWindowID, 1)
    }

    func testStartPagesInBothProfilesSwitchAndCloseCurrent() {
        let windows = [
            window(1, "Работа — Начальная страница", tabs: 1, url: "favorites://"),
            window(2, "Личное — Начальная страница", tabs: 1, url: "favorites://"),
        ]
        XCTAssertEqual(Switcher.decide(windows: windows, first: personal, second: work), SwitchPlan(
            target: .focus(windowID: 2), closeWindowID: 1, cycle: CycleState(profile: personal, visited: [2])))
    }

    func testUnknownOrNoWindowTargetsSecondProfile() {
        XCTAssertEqual(Switcher.decide(windows: [], first: personal, second: work),
                       SwitchPlan(target: .openNew(profile: work), closeWindowID: nil, cycle: nil))
        let unknown = window(9, "Частный доступ", tabs: 1, url: "favorites://")
        XCTAssertEqual(Switcher.decide(windows: [unknown], first: personal, second: work),
                       SwitchPlan(target: .openNew(profile: work), closeWindowID: nil, cycle: nil))
    }

    func testRejectsInvalidProfilePair() {
        XCTAssertNil(Switcher.decide(windows: [], first: personal, second: personal))
        XCTAssertNil(Switcher.decide(windows: [], first: "", second: work))
    }
}
