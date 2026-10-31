import XCTest
@testable import SwitcherCore

final class TabTransferTests: XCTestCase {
    private let personal = "Личное"
    private let work = "Работа"

    private func tab(_ title: String, index: Int = 2, count: Int = 3, url: String = "https://jira.example.com/1") -> SafariTab {
        SafariTab(windowID: 1, windowTitle: title, index: index, tabCount: count, url: url)
    }

    private func window(_ id: Int, _ title: String) -> SafariWindow {
        SafariWindow(id: id, title: title, tabCount: 2, firstTabURL: "https://example.com")
    }

    func testMovesToFrontMostWindowOfOtherProfile() {
        let windows = [window(1, "Личное — Jira"), window(2, "Работа — Mail"), window(3, "Работа — Docs")]
        let plan = TabTransfer.plan(tab: tab("Личное — Jira"), windows: windows, profiles: [personal, work])
        XCTAssertEqual(plan, .success(TabTransferPlan(
            profile: work, target: .window(id: 2), cleanup: .closeTab(windowID: 1, index: 2))))
    }

    func testOpensNewWindowAndClosesSingleTabWindow() {
        let plan = TabTransfer.plan(
            tab: tab("Работа — Jira", index: 1, count: 1), windows: [window(1, "Работа — Jira")],
            profiles: [personal, work])
        XCTAssertEqual(plan, .success(TabTransferPlan(
            profile: personal, target: .newWindow(profile: personal), cleanup: .closeWindow(id: 1))))
    }

    func testKeepSourceCopiesTab() {
        let plan = TabTransfer.plan(
            tab: tab("Личное — Jira"), windows: [window(1, "Личное — Jira")], profiles: [personal, work],
            keepSource: true)
        XCTAssertEqual(try plan.get().cleanup, TabTransferPlan.Cleanup.none)
    }

    func testPreferredProfileFromRuleWins() {
        let windows = [window(1, "Личное — Jira"), window(4, "Клиент — CRM")]
        let plan = TabTransfer.plan(
            tab: tab("Личное — Jira"), windows: windows, profiles: [personal, work], preferredProfile: "Клиент")
        XCTAssertEqual(try plan.get().target, .window(id: 4))
        XCTAssertEqual(try plan.get().profile, "Клиент")
    }

    func testPreferredProfileEqualToCurrentFallsBackToNextProfile() {
        let plan = TabTransfer.plan(
            tab: tab("Работа — Jira"), windows: [], profiles: [personal, work], preferredProfile: work)
        XCTAssertEqual(try plan.get().profile, personal)
    }

    func testMovesToNextOfSeveralProfiles() {
        let windows = [window(1, "Работа — Jira"), window(2, "Личное — Mail"), window(3, "Клиент — CRM")]
        let plan = TabTransfer.plan(tab: tab("Работа — Jira"), windows: windows, profiles: [personal, work, "Клиент"])
        XCTAssertEqual(try plan.get().target, .window(id: 3))
    }

    func testExplicitProfileWinsOverRules() {
        let windows = [window(1, "Личное — Jira"), window(2, "Работа — Mail"), window(3, "Клиент — CRM")]
        let plan = TabTransfer.plan(tab: tab("Личное — Jira"), windows: windows, profiles: [personal, work],
                                    preferredProfile: work, explicitProfile: "Клиент")
        XCTAssertEqual(try plan.get().target, .window(id: 3))
        XCTAssertEqual(TabTransfer.plan(tab: tab("Личное — Jira"), windows: windows, profiles: [personal, work],
                                        explicitProfile: personal), .failure(.alreadyInProfile))
    }

    func testRejectsStartPageAndBadPair() {
        XCTAssertEqual(TabTransfer.plan(tab: tab("Личное — x", url: "favorites://"), windows: [], profiles: [personal, work]),
                       .failure(.nothingToMove))
        XCTAssertEqual(TabTransfer.plan(tab: tab("Личное — x"), windows: [], profiles: [personal, personal]),
                       .failure(.profilesNotConfigured))
    }
}

final class TabAttachTests: XCTestCase {
    private func window(_ id: Int, _ title: String) -> SafariWindow {
        SafariWindow(id: id, title: title, tabCount: 2, firstTabURL: "https://example.com")
    }

    private let profiles = ["Личное", "Работа"]

    func testPrefersWindowTheTabCameFrom() {
        let windows = [window(5, "Работа — Jira"), window(2, "Работа — Mail"), window(3, "Работа — Docs")]
        XCTAssertEqual(TabAttach.target(windows: windows, sourceWindowID: 5, profiles: profiles, detachedFrom: 3), 3)
    }

    func testFallsBackToFrontMostWindowOfSameProfile() {
        let windows = [window(5, "Работа — Jira"), window(1, "Личное — Mail"), window(2, "Работа — Mail")]
        // The original window is gone (or belongs to another profile).
        XCTAssertEqual(TabAttach.target(windows: windows, sourceWindowID: 5, profiles: profiles, detachedFrom: 9), 2)
        XCTAssertEqual(TabAttach.target(windows: windows, sourceWindowID: 5, profiles: profiles, detachedFrom: 1), 2)
    }

    func testNoOtherWindowOfProfile() {
        let windows = [window(5, "Работа — Jira"), window(1, "Личное — Mail")]
        XCTAssertNil(TabAttach.target(windows: windows, sourceWindowID: 5, profiles: profiles, detachedFrom: nil))
    }
}
