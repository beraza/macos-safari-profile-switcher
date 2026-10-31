import XCTest
@testable import SwitcherCore

final class TabSearchTests: XCTestCase {
    private let windows = [
        SafariWindow(id: 1, title: "Работа — Jira", tabCount: 2, firstTabURL: ""),
        SafariWindow(id: 2, title: "Личное — Почта", tabCount: 2, firstTabURL: ""),
    ]
    private let tabs = [
        1: WindowTabs(titles: ["Jira board", "Ёлка — дизайн"], urls: ["https://jira.example.com/b", "https://figma.com/elka"], current: 0),
        2: WindowTabs(titles: ["Почта", "Board games shop"], urls: ["https://mail.example.com", "https://shop.ru/jira"], current: 1),
    ]

    private func search(_ query: String) -> [String] {
        TabSearch.results(query: query, windows: windows, tabs: tabs, profiles: ["Работа", "Личное"]).map(\.title)
    }

    func testEmptyQueryListsAllTabsInOrder() {
        XCTAssertEqual(search("  "), ["Jira board", "Ёлка — дизайн", "Почта", "Board games shop"])
    }

    func testRanksTitlePrefixThenTitleThenAddress() {
        XCTAssertEqual(search("board"), ["Board games shop", "Jira board"])
        XCTAssertEqual(search("jira"), ["Jira board", "Board games shop"])
    }

    func testAllWordsCaseAndAccentInsensitive() {
        XCTAssertEqual(search("елка ДИЗАЙН"), ["Ёлка — дизайн"])
        XCTAssertEqual(search("mail почта"), ["Почта"])
        XCTAssertEqual(search("nothing"), [])
    }

    func testResultsCarryWindowTabAndProfile() {
        let result = TabSearch.results(query: "shop", windows: windows, tabs: tabs, profiles: ["Работа", "Личное"]).first
        XCTAssertEqual(result, TabSearchResult(windowID: 2, tabIndex: 1, title: "Board games shop",
                                               url: "https://shop.ru/jira", profile: "Личное"))
    }
}

final class WindowTransferTests: XCTestCase {
    private let window = SafariWindow(id: 7, title: "Работа — Jira", tabCount: 3, firstTabURL: "https://a")

    func testMovesTabsToNextProfileSkippingStartPages() {
        let tabs = WindowTabs(titles: ["a", "start", "b"], urls: ["https://a", "favorites://", "https://b"], current: 1)
        let plan = WindowTransfer.plan(window: window, tabs: tabs, profiles: ["Личное", "Работа"])
        XCTAssertEqual(plan, .success(WindowTransferPlan(
            profile: "Личное", urls: ["https://a", "https://b"], currentTab: 1, closeSource: true)))
    }

    func testExplicitProfileAndErrors() {
        let tabs = WindowTabs(titles: ["a"], urls: ["https://a"], current: 0)
        XCTAssertEqual(try WindowTransfer.plan(window: window, tabs: tabs, profiles: [], explicitProfile: "Клиент",
                                               keepSource: true).get().closeSource, false)
        XCTAssertEqual(WindowTransfer.plan(window: window, tabs: tabs, profiles: [], explicitProfile: "Работа"),
                       .failure(.alreadyInProfile))
        let empty = WindowTabs(titles: ["s"], urls: ["favorites://"], current: 0)
        XCTAssertEqual(WindowTransfer.plan(window: window, tabs: empty, profiles: ["Личное", "Работа"]), .failure(.nothingToMove))
    }
}
