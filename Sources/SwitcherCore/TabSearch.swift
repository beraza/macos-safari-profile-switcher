import Foundation

/// A tab found by `TabSearch`.
public struct TabSearchResult: Equatable, Sendable {
    public let windowID: Int
    /// 0-based.
    public let tabIndex: Int
    public let title: String
    public let url: String
    public let profile: String?

    public init(windowID: Int, tabIndex: Int, title: String, url: String, profile: String?) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
        self.profile = profile
    }
}

/// Finds tabs across all windows (and so all profiles) by title and address.
public enum TabSearch {
    /// Every word of `query` has to occur in the title or the address (case- and accent-insensitive).
    /// Titles starting with the query come first, then titles with all the words, then address matches;
    /// within each, windows front to back and tabs in order. An empty query lists every tab.
    public static func results(
        query: String, windows: [SafariWindow], tabs: [Int: WindowTabs], profiles: [String]
    ) -> [TabSearchResult] {
        let query = normalized(query)
        let words = query.split(separator: " ").map(String.init)
        var ranked: [(rank: Int, order: Int, result: TabSearchResult)] = []
        for window in windows {
            guard let windowTabs = tabs[window.id] else { continue }
            let profile = ProfileMatcher.profile(of: window, among: profiles)
            for (index, title) in windowTabs.titles.enumerated() {
                let url = windowTabs.urls.indices.contains(index) ? windowTabs.urls[index] : ""
                let result = TabSearchResult(windowID: window.id, tabIndex: index, title: title, url: url, profile: profile)
                guard !words.isEmpty else {
                    ranked.append((0, ranked.count, result))
                    continue
                }
                let title = normalized(title)
                let address = normalized(url)
                guard words.allSatisfy({ title.contains($0) || address.contains($0) }) else { continue }
                let rank = title.hasPrefix(query) ? 0 : words.allSatisfy(title.contains) ? 1 : 2
                ranked.append((rank, ranked.count, result))
            }
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.result)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }
}
