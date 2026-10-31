import XCTest
@testable import SafariProfileSwitcher
import SwitcherCore

@MainActor
final class AppControllerTests: XCTestCase {
    private var safari: FakeSafari!
    private var settings: AppSettings!
    private var controller: AppController!
    private var suite = ""

    override func setUp() async throws {
        suite = "SafariProfileSwitcherTests.\(UUID().uuidString)"
        safari = FakeSafari()
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.switchProfiles = ["Личное", "Работа"]
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        controller = nil
    }

    /// Creates the controller after the test has set up Safari's windows.
    private func start() {
        controller = AppController(customSettings: settings, promptForAccessibility: false, safari: safari,
                                   registersHotKeys: false)
    }

    private var front: FakeSafari.Window? { safari.windowList.first }

    // MARK: - Switching

    func testSwitchFocusesOtherProfileAndClosesEmptyStartPage() async throws {
        safari.addWindow(profile: "Личное", tabs: [.start])
        let work = safari.addWindow(profile: "Работа", tabs: [.page("jira")])
        start()
        try await controller.switchProfile()
        XCTAssertEqual(safari.windowList.map(\.id), [work], "the empty start page window of Личное is closed")
    }

    func testSwitchOpensNewWindowInPlace() async throws {
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        safari.windowList[0].frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        start()
        try await controller.switchProfile()
        XCTAssertEqual(front?.profile, "Работа")
        XCTAssertEqual(front?.frame, CGRect(x: 10, y: 20, width: 900, height: 700))
        XCTAssertNotNil(safari.window(personal), "a window with a page stays open")
    }

    func testGoToProfileByNumberThenCyclesItsWindows() async throws {
        safari.profiles = ["Личное", "Работа", "Клиент"]
        settings.switchProfiles = ["Личное", "Работа", "Клиент"]
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        let crm = safari.addWindow(profile: "Клиент", tabs: [.page("crm")])
        let docs = safari.addWindow(profile: "Клиент", tabs: [.page("docs")])
        start()
        try await controller.goToProfile(number: 3)
        XCTAssertEqual(front?.id, crm)
        try await controller.goToProfile(number: 3)
        XCTAssertEqual(front?.id, docs, "pressed again: the next window of the profile")
        try await controller.goToProfile(number: 2)
        XCTAssertEqual(front?.profile, "Работа", "a profile without windows gets a new one")
        try await controller.goToProfile(number: 9)
        XCTAssertEqual(front?.profile, "Работа", "no profile at that place: nothing happens")
    }

    // MARK: - Tabs and windows

    func testMoveTabToProfileByNumberOpensFirstThenCloses() async throws {
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("a"), .page("b")])
        let work = safari.addWindow(profile: "Работа", tabs: [.page("jira")])
        start()
        try await controller.moveTabToProfile(number: 2)
        XCTAssertEqual(safari.window(work)?.tabs.last?.url, "https://b.example/")
        XCTAssertEqual(safari.window(personal)?.tabs.map(\.title), ["a"])
        XCTAssertEqual(front?.id, work)
    }

    func testMoveWindowOpensAllTabsInNextProfile() async throws {
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("a"), .start, .page("b")])
        safari.windowList[0].current = 2
        start()
        try await controller.moveWindowToOtherProfile()
        XCTAssertNil(safari.window(personal), "the source window is closed")
        XCTAssertEqual(front?.profile, "Работа")
        XCTAssertEqual(front?.tabs.map(\.url), ["https://a.example/", "https://b.example/"], "start pages stay behind")
        XCTAssertEqual(front?.current, 1, "the tab that was current stays current")
    }

    func testMoveWindowKeepsSourceWhenCopying() async throws {
        settings.keepSourceTab = true
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("a")])
        start()
        try await controller.moveWindowToOtherProfile()
        XCTAssertNotNil(safari.window(personal))
    }

    func testDetachAndAttachTab() async throws {
        let home = safari.addWindow(profile: "Работа", tabs: [.page("a"), .page("b")])
        start()
        try await controller.detachTab()
        let detached = try XCTUnwrap(front?.id)
        XCTAssertNotEqual(detached, home)
        XCTAssertEqual(settings.detachedFrom[detached], home)
        try await controller.attachTab()
        XCTAssertNil(safari.window(detached), "the emptied window is gone")
        XCTAssertEqual(safari.window(home)?.tabs.count, 2)
        XCTAssertEqual(settings.detachedFrom, [:])
    }

    // MARK: - Switcher choices

    func testActivatingProfileLaunchesSafariAndUsesItsOwnWindow() async throws {
        safari.isRunning = false
        safari.windowOnLaunch = FakeSafari.Window(id: 0, profile: "Работа", tabs: [.start])
        start()
        let item = HUDItem(target: .profile("Работа"), title: "", profile: "Работа", count: 0)
        try await controller.activate(item, windows: [])
        XCTAssertTrue(safari.isRunning)
        XCTAssertEqual(safari.windowList.count, 1, "no second window next to the one Safari opened")
        XCTAssertGreaterThan(safari.activations, 0)
    }

    func testActivatingProfileReplacesSafarisEmptyWindowOfAnotherProfile() async throws {
        safari.isRunning = false
        safari.windowOnLaunch = FakeSafari.Window(id: 0, profile: "Личное", tabs: [.start])
        start()
        let item = HUDItem(target: .profile("Работа"), title: "", profile: "Работа", count: 0)
        try await controller.activate(item, windows: [])
        XCTAssertEqual(safari.windowList.map(\.profile), ["Работа"])
    }

    func testActivatingWindowSelectsChosenTab() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        let work = safari.addWindow(profile: "Работа", tabs: [.page("a"), .page("b"), .page("c")])
        start()
        let windows = try safari.windows()
        let item = HUDItem(target: .window(id: work), title: "c", profile: "Работа", count: 3,
                           tabs: ["a", "b", "c"], currentTab: 2)
        try await controller.activate(item, windows: windows, tab: 0)
        XCTAssertEqual(front?.id, work)
        XCTAssertEqual(front?.current, 0)
    }

    func testSelectionActionsWorkOnTheChosenTab() async throws {
        let work = safari.addWindow(profile: "Работа", tabs: [.page("a"), .page("b")])
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        start()
        try await controller.run(.moveTab(windowID: work, tab: 0))
        XCTAssertEqual(safari.window(personal)?.tabs.map(\.title).last, "https://a.example/")
        XCTAssertEqual(safari.window(work)?.tabs.map(\.title), ["b"])
    }

    func testReturnsToTheWindowSafariWasLeftIn() async throws {
        let personal = safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        let work = safari.addWindow(profile: "Работа", tabs: [.page("jira")])
        start()
        safari.focusedWindow = personal
        try safari.focus(windowID: work)
        controller.showLastWindow()
        await controller.waitUntilIdle()
        XCTAssertEqual(front?.id, personal)
    }

    // MARK: - Queue and links

    func testQueuedActionsDontInterleave() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        start()
        controller.openWindow(profile: "Работа")
        controller.openWindow(profile: "Личное")
        await controller.waitUntilIdle()
        XCTAssertEqual(safari.windowList.map(\.profile), ["Личное", "Работа", "Личное"])
        XCTAssertNil(controller.lastError)
    }

    func testLinkWithoutRuleGoesToSafarisOwnSettings() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        start()
        controller.openLink(URL(string: "https://example.com/?utm_source=x")!, sourceApp: "com.apple.mail")
        await controller.waitUntilIdle()
        XCTAssertEqual(safari.handedOff, [URL(string: "https://example.com/")!], "cleaned and handed to Safari")
    }

    func testLinkByRuleOpensInProfileWindow() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        let work = safari.addWindow(profile: "Работа", tabs: [.page("jira")])
        settings.linkRules = [LinkRule(pattern: "github.com/work-org", profile: "Работа")]
        start()
        controller.openLink(URL(string: "https://github.com/work-org/repo")!, sourceApp: nil)
        await controller.waitUntilIdle()
        XCTAssertEqual(front?.id, work)
        XCTAssertEqual(front?.tabs.last?.url, "https://github.com/work-org/repo")
        XCTAssertEqual(safari.handedOff, [])
    }

    func testIgnoresLinksThatArentWebLinks() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        settings.defaultLinkProfile = "Личное"
        start()
        controller.openLink(URL(string: "javascript:alert(1)")!, sourceApp: nil)
        controller.openLink(URL(string: "smb://server/share")!, sourceApp: nil)
        await controller.waitUntilIdle()
        XCTAssertEqual(front?.tabs.count, 1)
        XCTAssertEqual(safari.handedOff, [])
    }

    func testLinkToMissingProfileFallsBackToSafari() async throws {
        safari.addWindow(profile: "Личное", tabs: [.page("mail")])
        settings.linkRules = [LinkRule(pattern: "example.org", profile: "Удалённый")]
        start()
        controller.openLink(URL(string: "https://example.org/")!, sourceApp: nil)
        await controller.waitUntilIdle()
        XCTAssertEqual(safari.handedOff, [URL(string: "https://example.org/")!], "a link is never lost")
        XCTAssertNotNil(controller.lastError)
    }

    // MARK: - Shortcuts

    func testNumberedShortcutsOnlyForListedProfilesAndFreeKeys() throws {
        safari.addWindow(profile: "Личное")
        start()
        controller.safariActive = true
        let bindings = controller.hotKeyBindings
        XCTAssertNotNil(bindings[.goToProfile(2)])
        XCTAssertNil(bindings[.goToProfile(3)], "only as many as there are profiles in the list")
        XCTAssertEqual(bindings[.moveTabToProfile(1)]?.displayString, "⌃⌥1")
        settings.setShortcut(NumberModifier.option.shortcut(1), for: .searchTabs)
        XCTAssertNil(controller.hotKeyBindings[.goToProfile(1)], "an action's keys win")
    }
}

@MainActor
final class SettingsBackupTests: XCTestCase {
    func testExportImportRoundTripAndValidation() throws {
        let source = AppSettings(defaults: UserDefaults(suiteName: "SafariProfileSwitcherTests.backup.a")!)
        defer { UserDefaults().removePersistentDomain(forName: "SafariProfileSwitcherTests.backup.a") }
        source.switchProfiles = ["Работа", "Личное", ProfileMatcher.privateProfile]
        source.linkRules = [LinkRule(pattern: "*.ktalk.ru", profile: "", targetApp: "kontur.talk", targetScheme: "ktalk")]
        source.profileBadges = ["Работа": "W"]
        source.hudMode = .windows
        source.setShortcut(Shortcut(keyCode: 0, modifiers: [.control, .option], keyLabel: "A"), for: .searchTabs)
        let data = try source.exportData()

        let target = AppSettings(defaults: UserDefaults(suiteName: "SafariProfileSwitcherTests.backup.b")!)
        defer { UserDefaults().removePersistentDomain(forName: "SafariProfileSwitcherTests.backup.b") }
        try target.importData(data)
        XCTAssertEqual(target.switchProfiles, source.switchProfiles)
        XCTAssertEqual(target.linkRules, source.linkRules)
        XCTAssertEqual(target.profileBadges, ["Работа": "W"])
        XCTAssertEqual(target.hudMode, .windows)
        XCTAssertEqual(target.shortcuts[.searchTabs]?.displayString, "⌃⌥A")
    }

    func testImportRejectsForeignFilesAndUnsafeValues() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "SafariProfileSwitcherTests.backup.c")!)
        defer { UserDefaults().removePersistentDomain(forName: "SafariProfileSwitcherTests.backup.c") }
        XCTAssertThrowsError(try settings.importData(Data(#"{"switchProfiles": ["X"]}"#.utf8)))
        XCTAssertThrowsError(try settings.importData(Data("not json".utf8)))
        let file = #"""
        {"app": "SafariProfileSwitcher", "hudDelay": 99, "profileBadges": {"P": "TOOLONG"},
         "shortcuts": {"custom": {"switchProfile": {"keyCode": 0, "modifiers": 0, "keyLabel": "A"}}, "disabled": []}}
        """#
        try settings.importData(Data(file.utf8))
        XCTAssertEqual(settings.hudDelay, 0.6)
        XCTAssertEqual(settings.profileBadges["P"], "TOOL")
        XCTAssertEqual(settings.shortcuts[.switchProfile], ShortcutAction.switchProfile.defaultShortcut,
                       "a shortcut without a modifier would swallow typing: the default stays")
    }
}
