import Foundation

/// Something in the settings that no longer fits what Safari shows.
public enum ProfileWarning: Equatable, Hashable, Sendable {
    /// A profile used in the settings or a link rule isn't among Safari's profiles (renamed or deleted?).
    case missingProfile(String)
    /// Safari has windows, but no window title starts with a known profile, so profiles can't be told apart.
    case unrecognizedTitles
}

public enum ProfileHealth {
    /// - Parameters:
    ///   - used: profiles the settings refer to (switching list, link rules, default link profile).
    ///   - detected: profiles found in Safari's menu; empty if unknown (then nothing is reported missing).
    ///   - windowTitles: titles of Safari's windows.
    public static func warnings(used: [String], detected: [String], windowTitles: [String]) -> [ProfileWarning] {
        var result: [ProfileWarning] = []
        if !detected.isEmpty {
            result += ProfileMatcher.cleaned(used).filter { !detected.contains($0) }.map(ProfileWarning.missingProfile)
        }
        let known = ProfileMatcher.cleaned(detected + used)
        let titles = windowTitles.filter { !$0.isEmpty }
        if !known.isEmpty, !titles.isEmpty,
           !titles.contains(where: { ProfileMatcher.profile(ofTitle: $0, among: known) != nil }) {
            result.append(.unrecognizedTitles)
        }
        return result
    }
}
