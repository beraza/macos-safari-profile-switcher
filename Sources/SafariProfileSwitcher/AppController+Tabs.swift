import AppKit
import SwitcherCore

/// Numbered profiles, whole windows, and actions on a tab or window chosen in the switcher or the search.
extension AppController {
    /// The profile at place `number` (1…9) in the switching list.
    func profile(number: Int) -> String? {
        settings.switchProfiles.indices.contains(number - 1) ? settings.switchProfiles[number - 1] : nil
    }

    /// ⌥N: to the profile's front-most window (a new one if it has none); pressed again, its next window.
    func goToProfile(number: Int) async throws {
        guard let target = profile(number: number) else { return }
        let windows = try safari.windows()
        let plan = Switcher.decide(
            windows: windows, target: target, profiles: knownProfiles, cycle: cycle, closeEmpty: settings.closeEmptyWindow)
        try await apply(plan, windows: windows)
    }

    /// ⌃⌥N: the current tab to the profile at place N.
    func moveTabToProfile(number: Int) async throws {
        guard let target = profile(number: number) else { return }
        try await moveTabToOtherProfile(target)
    }

    /// Opens all tabs of a window (the front one by default) in a new window of the next profile (or
    /// `profile`), in place of it, and closes it unless tabs are copied. Only addresses move: history and
    /// cookies stay in the old profile.
    func moveWindowToOtherProfile(windowID: Int? = nil, profile: String? = nil) async throws {
        let windows = try safari.windows()
        guard let window = windowID.map({ id in windows.first { $0.id == id } }) ?? windows.first else {
            throw SafariError.noWindows
        }
        let tabs = try safari.tabs()[window.id] ?? WindowTabs(titles: [], current: 0)
        let plan: WindowTransferPlan
        switch WindowTransfer.plan(window: window, tabs: tabs, profiles: settings.switchProfiles,
                                   explicitProfile: profile, keepSource: settings.keepSourceTab) {
        case .success(let value): plan = value
        case .failure(.profilesNotConfigured):
            throw AppError(String(localized: "Choose at least two profiles in Settings"))
        case .failure(.nothingToMove):
            throw AppError(String(localized: "Nothing to move: the window only shows start pages"))
        case .failure(.alreadyInProfile):
            throw AppError(String(localized: "The window is already in this profile"))
        }
        // Open everything first, close after: a failure must never lose the tabs.
        let id = try await openNewWindow(profile: plan.profile, replacing: window.id)
        try safari.setCurrentTabURL(plan.urls[0], windowID: id)
        for url in plan.urls.dropFirst() {
            try safari.openTab(url: url, windowID: id)
        }
        try safari.selectTab(index: plan.currentTab + 1, windowID: id)
        try safari.focus(windowID: id)
        if plan.closeSource {
            try safari.close(windowID: window.id)
        }
        cycle = nil
    }

    /// Something to do with the tab or window selected in the switcher.
    func run(_ action: HUDController.SelectionAction) async throws {
        switch action {
        case .moveTab(let windowID, let tab):
            try bringToFront(windowID: windowID, tab: tab)
            try await moveTabToOtherProfile()
        case .detachTab(let windowID, let tab):
            try bringToFront(windowID: windowID, tab: tab)
            // "Move Tab to New Window" acts on Safari's key window: let the activation land first.
            await safari.waitUntilActive()
            try await detachTab()
        case .moveWindow(let windowID):
            try await moveWindowToOtherProfile(windowID: windowID)
        }
    }

    /// A tab found by the search.
    func showTab(windowID: Int, tab: Int) {
        perform { try $0.bringToFront(windowID: windowID, tab: tab) }
    }

    /// Makes `tab` (0-based) current in the window and brings the window and Safari to the front.
    func bringToFront(windowID: Int, tab: Int?) throws {
        if let tab {
            try safari.selectTab(index: tab + 1, windowID: windowID)
        }
        try safari.focus(windowID: windowID)
        safari.activate()
        cycle = nil
    }
}
