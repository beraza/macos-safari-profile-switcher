import XCTest
@testable import SwitcherCore

final class LinkRuleTests: XCTestCase {
    private func match(_ pattern: String, _ url: String, app: String = "", from source: String? = nil) -> Bool {
        RuleMatcher.matches(LinkRule(pattern: pattern, sourceApp: app, profile: "P"), url: URL(string: url)!, sourceApp: source)
    }

    func testDomainIncludesSubdomains() {
        XCTAssertTrue(match("example.com", "https://example.com/a"))
        XCTAssertTrue(match("example.com", "https://www.example.com"))
        XCTAssertTrue(match("Example.COM", "http://mail.EXAMPLE.com:8443/x"))
        XCTAssertFalse(match("example.com", "https://notexample.com"))
        XCTAssertFalse(match("example.com", "https://example.com.evil.org"))
    }

    func testWildcardMeansSubdomainsOnly() {
        XCTAssertTrue(match("*.corp.example.com", "https://jira.corp.example.com"))
        XCTAssertFalse(match("*.corp.example.com", "https://corp.example.com"))
    }

    func testPathPrefixIsSegmentAware() {
        XCTAssertTrue(match("github.com/my-org/*", "https://github.com/my-org/repo/pulls"))
        XCTAssertTrue(match("https://github.com/My-Org", "https://github.com/my-org"))
        XCTAssertFalse(match("github.com/my-org", "https://github.com/my-organisation/repo"))
        XCTAssertFalse(match("github.com/my-org", "https://gist.github.com/other"))
    }

    func testSourceApp() {
        XCTAssertTrue(match("", "https://anything.org", app: "com.tinyspeck.slackmacgap", from: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(match("", "https://anything.org", app: "com.tinyspeck.slackmacgap", from: "com.apple.mail"))
        XCTAssertFalse(match("example.com", "https://example.com", app: "com.apple.mail", from: nil))
        XCTAssertTrue(match("example.com", "https://example.com", app: "", from: "com.apple.mail"))
        // A rule with neither pattern nor app matches nothing.
        XCTAssertFalse(match("", "https://example.com"))
    }

    func testInternationalDomain() {
        XCTAssertTrue(match("пример.рф", "https://www.xn--e1afmkfd.xn--p1ai/"))
        XCTAssertTrue(match("xn--e1afmkfd.xn--p1ai", "https://пример.рф/"))
    }

    func testFirstMatchingRuleWins() {
        let rules = [
            LinkRule(pattern: "github.com/work-org", profile: "Работа"),
            LinkRule(pattern: "github.com", profile: "Личное"),
        ]
        XCTAssertEqual(RuleMatcher.profile(for: URL(string: "https://github.com/work-org/x")!, sourceApp: nil, rules: rules), "Работа")
        XCTAssertEqual(RuleMatcher.profile(for: URL(string: "https://github.com/me")!, sourceApp: nil, rules: rules), "Личное")
        XCTAssertNil(RuleMatcher.profile(for: URL(string: "https://apple.com")!, sourceApp: nil, rules: rules))
    }

    func testUnwrapsRedirectsAndStripsTracking() {
        let safeLink = URL(string: "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fjira.example.com%2Fbrowse%2FX-1%3Futm_source%3Dmail&data=abc")!
        XCTAssertEqual(LinkCleaner.clean(safeLink, stripTracking: true).absoluteString, "https://jira.example.com/browse/X-1")
        XCTAssertEqual(LinkCleaner.clean(safeLink, stripTracking: false).absoluteString, "https://jira.example.com/browse/X-1?utm_source=mail")
        let google = URL(string: "https://www.google.com/url?q=https://example.com/a?b%3D1%26fbclid%3Dxyz&sa=D")!
        XCTAssertEqual(LinkCleaner.clean(google, stripTracking: true).absoluteString, "https://example.com/a?b=1")
        let plain = URL(string: "https://example.com/?q=1")!
        XCTAssertEqual(LinkCleaner.clean(plain, stripTracking: true), plain)
    }
}
