import Foundation

/// Snapshot of a Safari browser window, as reported by AppleScript (front-most first).
public struct SafariWindow: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let tabCount: Int
    public let firstTabURL: String

    public init(id: Int, title: String, tabCount: Int, firstTabURL: String) {
        self.id = id
        self.title = title
        self.tabCount = tabCount
        self.firstTabURL = firstTabURL
    }

    /// URLs Safari uses for the start page / blank tab.
    static let startPageURLs: Set<String> = ["", "favorites://", "topsites://", "about:blank"]

    /// A window whose only tab is the start page.
    public var isEmptyStartPage: Bool {
        tabCount <= 1 && Self.startPageURLs.contains(firstTabURL)
    }
}

/// The current tab of a Safari window.
public struct SafariTab: Equatable, Sendable {
    public let windowID: Int
    public let windowTitle: String
    /// 1-based, as in AppleScript.
    public let index: Int
    public let tabCount: Int
    public let url: String

    public init(windowID: Int, windowTitle: String, index: Int, tabCount: Int, url: String) {
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.index = index
        self.tabCount = tabCount
        self.url = url
    }

    public var isStartPage: Bool { SafariWindow.startPageURLs.contains(url) }
}

public enum ProfileMatcher {
    /// Safari titles windows as "<Profile> — <Page title>".
    public static let separator = " — "

    /// Returns the profile from `profiles` the window title belongs to, preferring the longest name.
    public static func profile(ofTitle title: String, among profiles: [String]) -> String? {
        profiles
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .first { title == $0 || title.hasPrefix($0 + separator) }
    }

    /// The page part of a window title, without the "<Profile> — " prefix.
    public static func pageTitle(ofTitle title: String, profile: String?) -> String {
        guard let profile, title.hasPrefix(profile + separator) else { return title == profile ? "" : title }
        return String(title.dropFirst(profile.count + separator.count))
    }
}

public struct SwitchPlan: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case focus(windowID: Int)
        case openNew(profile: String)
    }

    public let target: Target
    /// Window to close after switching (the front window if it only shows the start page).
    public let closeWindowID: Int?
    /// Round of window cycling to pass to the next `decide` call.
    public let cycle: CycleState?

    public init(target: Target, closeWindowID: Int?, cycle: CycleState?) {
        self.target = target
        self.closeWindowID = closeWindowID
        self.cycle = cycle
    }
}

/// Windows of one profile already shown in the current round, in visiting order.
public struct CycleState: Equatable, Sendable {
    public let profile: String
    public let visited: [Int]

    public init(profile: String, visited: [Int]) {
        self.profile = profile
        self.visited = visited
    }
}

public enum Switcher {
    /// Decides what to do for one shortcut press: show the next not yet visited window of the
    /// current profile, and once all were shown, switch to the other profile.
    /// - Parameters:
    ///   - windows: Safari windows, front-most first.
    ///   - first: name of the first profile.
    ///   - second: name of the second profile.
    ///   - cycle: `SwitchPlan.cycle` from the previous press.
    ///   - closeEmpty: close the front window if it only shows the start page.
    /// - Returns: `nil` if the profile pair is not configured.
    public static func decide(
        windows: [SafariWindow], first: String, second: String, cycle: CycleState? = nil, closeEmpty: Bool = true
    ) -> SwitchPlan? {
        guard !first.isEmpty, !second.isEmpty, first != second else { return nil }
        let profiles = [first, second]
        func profile(of window: SafariWindow) -> String? {
            ProfileMatcher.profile(ofTitle: window.title, among: profiles)
        }
        let front = windows.first
        let currentProfile = front.flatMap(profile(of:))
        // Only close windows that belong to one of the configured profiles.
        let closeID = (closeEmpty && currentProfile != nil && front?.isEmptyStartPage == true) ? front?.id : nil

        if let front, let currentProfile {
            // The round continues only if the user is still on the window we showed last.
            let visited = cycle.flatMap { $0.profile == currentProfile && $0.visited.last == front.id ? $0.visited : nil }
                ?? [front.id]
            if let next = windows.first(where: { profile(of: $0) == currentProfile && !visited.contains($0.id) }) {
                return SwitchPlan(
                    target: .focus(windowID: next.id), closeWindowID: closeID,
                    cycle: CycleState(profile: currentProfile, visited: visited + [next.id]))
            }
        }

        let targetProfile = currentProfile == second ? first : second
        if let window = windows.first(where: { profile(of: $0) == targetProfile }) {
            return SwitchPlan(
                target: .focus(windowID: window.id), closeWindowID: closeID,
                cycle: CycleState(profile: targetProfile, visited: [window.id]))
        }
        return SwitchPlan(target: .openNew(profile: targetProfile), closeWindowID: closeID, cycle: nil)
    }
}
