import Foundation

/// "Open links like this in that profile".
public struct LinkRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// `example.com` (with subdomains), `*.example.com` (subdomains only), optionally with a path prefix
    /// (`github.com/my-org`). Empty matches any URL.
    public var pattern: String
    /// Bundle id of the app the link was opened from; empty matches any app.
    public var sourceApp: String
    public var profile: String

    public init(id: UUID = UUID(), pattern: String, sourceApp: String = "", profile: String) {
        self.id = id
        self.pattern = pattern
        self.sourceApp = sourceApp
        self.profile = profile
    }
}

public enum RuleMatcher {
    /// Profile of the first matching rule.
    public static func profile(for url: URL, sourceApp: String?, rules: [LinkRule]) -> String? {
        rules.first { !$0.profile.isEmpty && matches($0, url: url, sourceApp: sourceApp) }?.profile
    }

    public static func matches(_ rule: LinkRule, url: URL, sourceApp: String?) -> Bool {
        let app = rule.sourceApp.trimmingCharacters(in: .whitespaces)
        if !app.isEmpty && app.caseInsensitiveCompare(sourceApp ?? "") != .orderedSame { return false }
        let pattern = Pattern(rule.pattern)
        if pattern.host.isEmpty && pattern.path.isEmpty {
            return !app.isEmpty // A rule needs at least a pattern or an app.
        }
        guard let host = normalizedHost(url.host(percentEncoded: false) ?? "") else { return false }
        if !pattern.host.isEmpty {
            let suffixMatch = host.hasSuffix("." + pattern.host)
            guard pattern.subdomainsOnly ? suffixMatch : (host == pattern.host || suffixMatch) else { return false }
        }
        if !pattern.path.isEmpty {
            let path = url.path(percentEncoded: false).lowercased()
            guard path == pattern.path || path.hasPrefix(pattern.path + "/") else { return false }
        }
        return true
    }

    /// The host part of a URL or pattern in comparable form: lowercased, IDN as punycode, no trailing dot.
    static func normalizedHost(_ host: String) -> String? {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        // Let URL do the IDNA conversion so patterns and URLs end up in the same form.
        return URL(string: "https://\(host)/")?.host(percentEncoded: false)?.lowercased() ?? host
    }

    struct Pattern {
        var host = ""
        var subdomainsOnly = false
        /// Lowercased, starting with "/", without a trailing "/".
        var path = ""

        init(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces).lowercased()
            for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
                text.removeFirst(scheme.count)
            }
            while text.hasSuffix("*") || text.hasSuffix("/") { text.removeLast() }
            let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            var hostPart = String(parts.first ?? "")
            if let colon = hostPart.lastIndex(of: ":") { hostPart = String(hostPart[..<colon]) }
            if hostPart.hasPrefix("*.") {
                subdomainsOnly = true
                hostPart.removeFirst(2)
            }
            host = RuleMatcher.normalizedHost(hostPart) ?? ""
            if parts.count > 1, !parts[1].isEmpty {
                path = "/" + parts[1]
            }
        }
    }
}

public enum LinkCleaner {
    /// Query parameters that only track clicks.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "yclid", "msclkid", "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi",
    ]

    /// Unwraps redirect wrappers (Outlook Safe Links, Facebook, Google, Instagram, VK) and optionally
    /// removes tracking parameters (`utm_*`, `fbclid`, …).
    public static func clean(_ url: URL, unwrapRedirects: Bool = true, stripTracking: Bool) -> URL {
        var url = url
        if unwrapRedirects {
            for _ in 0..<3 {
                guard let inner = unwrap(url) else { break }
                url = inner
            }
        }
        return stripTracking ? withoutTracking(url) : url
    }

    /// The link a redirect wrapper points to. Only web links are taken: a wrapper must not turn into
    /// `javascript:`, `file:` or another scheme Safari would handle differently.
    static func unwrap(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> URL? {
            items.first { $0.name == name }?.value.flatMap(URL.init(string:)).flatMap { inner in
                ["http", "https"].contains(inner.scheme?.lowercased() ?? "") && inner.host() != nil ? inner : nil
            }
        }
        let path = url.path()
        if host.hasSuffix(".safelinks.protection.outlook.com") { return value("url") }
        if ["l.facebook.com", "lm.facebook.com", "l.instagram.com"].contains(host) { return value("u") }
        if (host == "www.google.com" || host == "google.com") && path == "/url" { return value("q") ?? value("url") }
        if host == "away.vk.com" || (host == "vk.com" && path == "/away.php") { return value("to") }
        return nil
    }

    /// Drops tracking parameters and leaves the rest of the query byte for byte as it was
    /// (re-encoding decoded items would turn `%2F` into `/` and break signed links).
    static func withoutTracking(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems
        else { return url }
        func isTracking(_ item: URLQueryItem) -> Bool {
            let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
            return name.hasPrefix("utm_") || trackingParameters.contains(name)
        }
        let kept = items.filter { !isTracking($0) }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}
