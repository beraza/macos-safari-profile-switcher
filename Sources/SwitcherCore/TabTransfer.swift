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
}

public enum TabTransfer {
    /// - Parameters:
    ///   - tab: the current tab of the front window.
    ///   - windows: Safari windows, front-most first.
    ///   - profiles: profiles to switch between, in order; without a rule the tab goes to the next one.
    ///   - preferredProfile: profile a link rule picks for the URL; used unless the tab is already there.
    ///   - keepSource: copy instead of move.
    public static func plan(
        tab: SafariTab, windows: [SafariWindow], profiles: [String],
        preferredProfile: String? = nil, keepSource: Bool = false
    ) -> Result<TabTransferPlan, TabTransferError> {
        let switching = ProfileMatcher.cleaned(profiles)
        guard switching.count >= 2 else { return .failure(.profilesNotConfigured) }
        guard !tab.isStartPage else { return .failure(.nothingToMove) }
        let profiles = ProfileMatcher.cleaned(switching + [preferredProfile ?? ""])
        func profile(of window: SafariWindow) -> String? { ProfileMatcher.profile(of: window, among: profiles) }

        let current = profile(of: SafariWindow(
            id: tab.windowID, title: tab.windowTitle, tabCount: tab.tabCount, firstTabURL: "", isPrivate: tab.isPrivate))
        guard let target = preferredProfile.flatMap({ $0.isEmpty || $0 == current ? nil : $0 })
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
