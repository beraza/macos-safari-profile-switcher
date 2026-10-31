import Foundation

/// Safari windows grouped by profile, for the menu bar list and the HUD.
public struct WindowGroup: Equatable, Sendable {
    /// `nil` for windows that belong to no known profile.
    public let profile: String?
    public let windows: [SafariWindow]

    public init(profile: String?, windows: [SafariWindow]) {
        self.profile = profile
        self.windows = windows
    }
}

public enum WindowGroups {
    /// Groups in the order of `profiles` (profiles without windows included, so they can get a new one),
    /// then windows of no known profile. Windows keep their front-to-back order.
    public static func make(windows: [SafariWindow], profiles: [String]) -> [WindowGroup] {
        var groups = profiles.filter { !$0.isEmpty }.map { profile in
            WindowGroup(profile: profile, windows: windows.filter {
                ProfileMatcher.profile(of: $0, among: profiles) == profile
            })
        }
        let others = windows.filter { ProfileMatcher.profile(of: $0, among: profiles) == nil }
        if !others.isEmpty { groups.append(WindowGroup(profile: nil, windows: others)) }
        return groups
    }
}
