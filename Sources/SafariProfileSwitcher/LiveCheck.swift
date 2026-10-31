import AppKit
import SwitcherCore

/// "Check how it works" in About: what needs Accessibility (Safari's menus, raising windows) tried on the
/// running Safari with temporary windows. The self-test can't do this part, it runs without the permission.
/// Only windows the check opened itself are closed; the front window is brought back at the end.
@MainActor
final class LiveCheck: ObservableObject {
    struct Step: Identifiable {
        let id = UUID()
        let name: String
        var passed: Bool?
        var detail = ""
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        steps = []

        guard step(String(localized: "Accessibility permission"), AXIsProcessTrusted(),
                   AXIsProcessTrusted() ? "" : String(localized: "Allow it above, then check again")),
              step(String(localized: "Safari is running"), SafariController.runningApp != nil)
        else { return }
        let originalFront = (try? SafariController.windows())?.first?.id
        defer {
            if let originalFront { try? SafariController.focus(windowID: originalFront) }
        }

        let profiles = SafariController.detectProfiles()
        guard step(String(localized: "Profiles in the File menu"), !profiles.isEmpty, profiles.joined(separator: ", "))
        else { return }

        await check(String(localized: "New window of a profile")) {
            let profile = profiles[0]
            let id = try await self.openWindow { try SafariController.openNewWindow(profile: profile) }
            defer { try? SafariController.close(windowID: id) }
            let title = try SafariController.windows().first { $0.id == id }?.title ?? ""
            return (ProfileMatcher.profile(ofTitle: title, among: profiles) == profile, "\(profile): \(title)")
        }
        await check(String(localized: "New Private Browsing window")) {
            let id = try await self.openWindow { try SafariController.openNewWindow(profile: ProfileMatcher.privateProfile) }
            defer { try? SafariController.close(windowID: id) }
            let window = try SafariController.windows().first { $0.id == id }
            return (window?.isPrivate == true, window?.title ?? "")
        }
        await check(String(localized: "Move a tab to a new window and raise a window")) {
            let base = "https://example.com/?spsw-check"
            let source = try SafariController.makeDocument(url: base + "-a")
            defer { try? SafariController.close(windowID: source) }
            try await Task.sleep(for: .milliseconds(500))
            try SafariController.openTab(url: base + "-b", windowID: source)
            try SafariController.focus(windowID: source)
            let known = Set(try SafariController.windows().map(\.id))
            guard try SafariController.moveCurrentTabToNewWindow() else {
                return (false, String(localized: "No “Move Tab to New Window” in the Window menu"))
            }
            let moved = try await SafariController.waitForNewWindow(excluding: known)
            defer { try? SafariController.close(windowID: moved) }
            try SafariController.focus(windowID: source)
            let front = try SafariController.windows().first?.id
            return (front == source, "")
        }
    }

    /// Opens a window and returns the id of the one that appeared.
    private func openWindow(_ open: () throws -> Void) async throws -> Int {
        let known = Set(try SafariController.windows().map(\.id))
        try open()
        return try await SafariController.waitForNewWindow(excluding: known)
    }

    @discardableResult
    private func step(_ name: String, _ passed: Bool, _ detail: String = "") -> Bool {
        steps.append(Step(name: name, passed: passed, detail: detail))
        return passed
    }

    private func check(_ name: String, _ body: () async throws -> (Bool, String)) async {
        steps.append(Step(name: name))
        let index = steps.count - 1
        do {
            let (passed, detail) = try await body()
            steps[index].passed = passed
            steps[index].detail = detail
        } catch {
            steps[index].passed = false
            steps[index].detail = error.localizedDescription
        }
    }
}
