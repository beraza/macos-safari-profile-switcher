import Foundation

/// What to do to move the current tab to another profile.
public struct TabTransferPlan: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// Open the URL in a new tab of this window (the front-most window of the profile).
        case window(id: Int)
        /// No window of the profile is open: open one and load the URL there.
        case newWindow(profile: String)
    }

    public enum Cleanup: Equatable, Sendable {
        case none
        case closeTab(windowID: Int, index: Int)
        /// The tab was the only one in its window.
        case closeWindow(id: Int)
    }

    public let profile: String
    public let target: Target
    public let cleanup: Cleanup

    public init(profile: String, target: Target, cleanup: Cleanup) {
        self.profile = profile
        self.target = target
        self.cleanup = cleanup
    }
}

public enum TabTransferError: Error, Equatable, Sendable {
    case profilesNotConfigured
    /// The tab shows the start page; there's no URL to move.
    case nothingToMove
    /// Moving to the profile the tab (window) is already in.
    case alreadyInProfile
}

public enum TabTransfer {
    /// - Parameters:
    ///   - tab: the current tab of the front window.
    ///   - windows: Safari windows, front-most first.
    ///   - profiles: profiles to switch between, in order; without a rule the tab goes to the next one.
    ///   - preferredProfile: profile a link rule picks for the URL; used unless the tab is already there.
    ///   - explicitProfile: the profile asked for ("move tab to profile N"); wins over rules.
    ///   - keepSource: copy instead of move.
    public static func plan(
        tab: SafariTab, windows: [SafariWindow], profiles: [String],
        preferredProfile: String? = nil, explicitProfile: String? = nil, keepSource: Bool = false
    ) -> Result<TabTransferPlan, TabTransferError> {
        let switching = ProfileMatcher.cleaned(profiles)
        guard switching.count >= 2 || explicitProfile != nil else { return .failure(.profilesNotConfigured) }
        guard !tab.isStartPage else { return .failure(.nothingToMove) }
        let profiles = ProfileMatcher.cleaned(switching + [preferredProfile ?? "", explicitProfile ?? ""])
        func profile(of window: SafariWindow) -> String? { ProfileMatcher.profile(of: window, among: profiles) }

        let current = profile(of: SafariWindow(
            id: tab.windowID, title: tab.windowTitle, tabCount: tab.tabCount, firstTabURL: "", isPrivate: tab.isPrivate))
        if let explicitProfile, explicitProfile == current { return .failure(.alreadyInProfile) }
        guard let target = explicitProfile
            ?? preferredProfile.flatMap({ $0.isEmpty || $0 == current ? nil : $0 })
            ?? ProfileMatcher.next(after: current, in: switching)
        else { return .failure(.profilesNotConfigured) }
        let destination: TabTransferPlan.Target = windows
            .first { $0.id != tab.windowID && profile(of: $0) == target }
            .map { .window(id: $0.id) } ?? .newWindow(profile: target)
        let cleanup: TabTransferPlan.Cleanup = keepSource ? .none
            : tab.tabCount <= 1 ? .closeWindow(id: tab.windowID)
            : .closeTab(windowID: tab.windowID, index: tab.index)
        return .success(TabTransferPlan(profile: target, target: destination, cleanup: cleanup))
    }
}

/// What to do to move a whole window (its tabs' URLs) to another profile: a new window of that profile.
public struct WindowTransferPlan: Equatable, Sendable {
    public let profile: String
    /// URLs to open in the new window, in tab order; start pages are left out.
    public let urls: [String]
    /// The tab to make current in the new window (0-based, among `urls`).
    public let currentTab: Int
    /// Close the source window afterwards (not when copying).
    public let closeSource: Bool

    public init(profile: String, urls: [String], currentTab: Int, closeSource: Bool) {
        self.profile = profile
        self.urls = urls
        self.currentTab = currentTab
        self.closeSource = closeSource
    }
}

public enum WindowTransfer {
    /// - Parameters:
    ///   - window: the window to move.
    ///   - tabs: its tabs (with URLs).
    ///   - profiles: profiles to switch between; without `explicitProfile` the window goes to the next one.
    ///   - explicitProfile: the profile asked for.
    ///   - keepSource: copy instead of move.
    public static func plan(
        window: SafariWindow, tabs: WindowTabs, profiles: [String], explicitProfile: String? = nil, keepSource: Bool = false
    ) -> Result<WindowTransferPlan, TabTransferError> {
        let switching = ProfileMatcher.cleaned(profiles)
        guard switching.count >= 2 || explicitProfile != nil else { return .failure(.profilesNotConfigured) }
        let current = ProfileMatcher.profile(of: window, among: ProfileMatcher.cleaned(switching + [explicitProfile ?? ""]))
        if let explicitProfile, explicitProfile == current { return .failure(.alreadyInProfile) }
        guard let target = explicitProfile ?? ProfileMatcher.next(after: current, in: switching) else {
            return .failure(.profilesNotConfigured)
        }
        let kept = tabs.urls.indices.filter { !SafariWindow.startPageURLs.contains(tabs.urls[$0]) }
        guard !kept.isEmpty else { return .failure(.nothingToMove) }
        let currentTab = kept.firstIndex(of: tabs.current) ?? kept.firstIndex { $0 > tabs.current } ?? kept.count - 1
        return .success(WindowTransferPlan(
            profile: target, urls: kept.map { tabs.urls[$0] }, currentTab: currentTab, closeSource: !keepSource))
    }
}

public enum TabAttach {
    /// Window to move a tab back into: the one it was detached from, if still open and of the same profile,
    /// otherwise the front-most other window of the same profile.
    /// - Parameters:
    ///   - windows: Safari windows, front-most first.
    ///   - detachedFrom: the window the source window's tab was detached from, if known.
    public static func target(
        windows: [SafariWindow], sourceWindowID: Int, profiles: [String], detachedFrom: Int?
    ) -> Int? {
        guard let source = windows.first(where: { $0.id == sourceWindowID }) else { return nil }
        let profile = ProfileMatcher.profile(of: source, among: profiles)
        let candidates = windows.filter {
            $0.id != sourceWindowID && $0.isPrivate == source.isPrivate
                && ProfileMatcher.profile(of: $0, among: profiles) == profile
        }
        if let detachedFrom, candidates.contains(where: { $0.id == detachedFrom }) {
            return detachedFrom
        }
        return candidates.first?.id
    }
}
