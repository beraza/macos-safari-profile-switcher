import AppKit
import SwitcherCore

/// What the app needs from Safari. `LiveSafari` does it with AppleScript and Accessibility (`SafariController`);
/// tests use a fake, so the app's decisions can be checked without Safari.
@MainActor
protocol SafariAPI: AnyObject {
    var isRunning: Bool { get }
    /// Launches Safari in the background if it isn't running and waits until it answers.
    func launch() async throws
    /// Brings Safari to the front.
    func activate()
    /// Launches or activates Safari the way the Dock does (it reopens a window if it has none).
    func reopen() async throws
    /// Hands a link to Safari like any other app would: Safari's own website settings pick the profile.
    func open(_ url: URL)

    /// Browser windows, front-most first.
    func windows() throws -> [SafariWindow]
    /// Tabs (titles, URLs, the current one) by window id.
    func tabs() throws -> [Int: WindowTabs]
    /// The current tab of the front window.
    func currentTab() throws -> SafariTab
    func bounds(windowID: Int) throws -> CGRect?
    func setBounds(_ rect: CGRect, windowID: Int) throws
    func isFullScreen(windowID: Int) -> Bool
    func setFullScreen(windowID: Int)
    func focus(windowID: Int) throws
    func close(windowID: Int) throws
    /// Opens `url` in a new tab at the end of the window and makes it current.
    func openTab(url: String, windowID: Int) throws
    func setCurrentTabURL(_ url: String, windowID: Int) throws
    /// Tab indexes are 1-based, as in AppleScript.
    func selectTab(index: Int, windowID: Int) throws
    func closeTab(index: Int, windowID: Int) throws
    func moveTab(index: Int, from source: Int, to target: Int) throws
    /// Opens a new window of `profile` (or Private Browsing) from Safari's File menu.
    func openNewWindow(profile: String) throws
    /// Presses Window → Move Tab to New Window; `false` if the item isn't there.
    func moveCurrentTabToNewWindow() throws -> Bool
    /// Waits until a window not in `known` appears and returns its id.
    func waitForNewWindow(excluding known: Set<Int>) async throws -> Int
    /// Profile names from the File menu (or window titles).
    func detectProfiles() -> [String]
    /// Safari's focused window: the one in front when Safari was left, whose profile the menu bar shows.
    func focusedWindowID() -> Int?
    /// Waits (up to a second) until Safari is the active app, e.g. before pressing an item in its menus.
    func waitUntilActive() async
}

/// The real Safari.
@MainActor
final class LiveSafari: SafariAPI {
    var isRunning: Bool { SafariController.runningApp != nil }

    func launch() async throws {
        guard !isRunning else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            throw AppController.AppError(String(localized: "Safari not found"))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? SafariController.windows()) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SafariError.timeout
    }

    func activate() {
        SafariController.runningApp?.activate()
    }

    func reopen() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            throw AppController.AppError(String(localized: "Safari not found"))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func open(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    func windows() throws -> [SafariWindow] { try SafariController.windows() }
    func tabs() throws -> [Int: WindowTabs] { try SafariController.tabs() }
    func currentTab() throws -> SafariTab { try SafariController.currentTab() }
    func bounds(windowID: Int) throws -> CGRect? { try SafariController.bounds(windowID: windowID) }
    func setBounds(_ rect: CGRect, windowID: Int) throws { try SafariController.setBounds(rect, windowID: windowID) }
    func isFullScreen(windowID: Int) -> Bool { SafariController.isFullScreen(windowID: windowID) }
    func setFullScreen(windowID: Int) { SafariController.setFullScreen(windowID: windowID) }
    func focus(windowID: Int) throws { try SafariController.focus(windowID: windowID) }
    func close(windowID: Int) throws { try SafariController.close(windowID: windowID) }
    func openTab(url: String, windowID: Int) throws { try SafariController.openTab(url: url, windowID: windowID) }
    func setCurrentTabURL(_ url: String, windowID: Int) throws { try SafariController.setCurrentTabURL(url, windowID: windowID) }
    func selectTab(index: Int, windowID: Int) throws { try SafariController.selectTab(index: index, windowID: windowID) }
    func closeTab(index: Int, windowID: Int) throws { try SafariController.closeTab(index: index, windowID: windowID) }
    func moveTab(index: Int, from source: Int, to target: Int) throws {
        try SafariController.moveTab(index: index, from: source, to: target)
    }
    func openNewWindow(profile: String) throws { try SafariController.openNewWindow(profile: profile) }
    func moveCurrentTabToNewWindow() throws -> Bool { try SafariController.moveCurrentTabToNewWindow() }
    func waitForNewWindow(excluding known: Set<Int>) async throws -> Int {
        try await SafariController.waitForNewWindow(excluding: known)
    }
    func detectProfiles() -> [String] { SafariController.detectProfiles() }
    func focusedWindowID() -> Int? { SafariController.focusedWindowID() }

    func waitUntilActive() async {
        let deadline = ContinuousClock.now + .seconds(1)
        while SafariController.runningApp?.isActive == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
