import Foundation

/// Something in the settings that no longer fits what Safari shows.
public enum ProfileWarning: Equatable, Hashable, Sendable {
    /// A profile used in the settings or a link rule isn't among Safari's profiles (renamed or deleted?).
    case missingProfile(String)
}

public enum ProfileHealth {
    /// - Parameters:
    ///   - used: profiles the settings refer to (switching list, link rules, default link profile).
    ///   - detected: profiles found in Safari's menu; empty if unknown (then nothing is reported missing).
    public static func warnings(used: [String], detected: [String]) -> [ProfileWarning] {
        guard !detected.isEmpty else { return [] }
        return ProfileMatcher.cleaned(used)
            .filter { $0 != ProfileMatcher.privateProfile && !detected.contains($0) }
            .map(ProfileWarning.missingProfile)
    }
}
