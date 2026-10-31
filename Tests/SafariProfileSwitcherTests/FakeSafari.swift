import AppKit
@testable import SafariProfileSwitcher
import SwitcherCore

/// A Safari in memory: windows front to back, each with a profile (or private) and tabs.
@MainActor
final class FakeSafari: SafariAPI {
    struct Tab: Equatable {
        var title: String
        var url: String

        static let start = Tab(title: "Начальная страница", url: "favorites://")
        static func page(_ name: String) -> Tab { Tab(title: name, url: "https://\(name).example/") }
    }

    struct Window: Equatable {
        var id: Int
        var profile: String?
        var isPrivate = false
        var tabs: [Tab]
        var current = 0
        var frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var fullScreen = false
    }

    var isRunning = true
    /// Front to back.
    var windowList: [Window] = []
    var profiles = ["Личное", "Работа"]
    /// What Safari opens by itself when launched.
    var windowOnLaunch: Window?
    /// Links handed to Safari as from another app.
    var handedOff: [URL] = []
    var activations = 0
    private var nextID = 100

    func window(_ id: Int) -> Window? { windowList.first { $0.id == id } }

    private func index(_ id: Int) throws -> Int {
        guard let index = windowList.firstIndex(where: { $0.id == id }) else { throw SafariError.script("no window \(id)") }
        return index
    }

    private func title(of window: Window) -> String {
        let page = window.tabs.indices.contains(window.current) ? window.tabs[window.current].title : ""
        return window.isPrivate ? page : "\(window.profile ?? "?") — \(page)"
    }

    @discardableResult
    func addWindow(profile: String?, isPrivate: Bool = false, tabs: [Tab] = [.start], front: Bool = false) -> Int {
        nextID += 1
        let window = Window(id: nextID, profile: profile, isPrivate: isPrivate, tabs: tabs, current: tabs.count - 1)
        if front { windowList.insert(window, at: 0) } else { windowList.append(window) }
        return nextID
    }

    // MARK: - SafariAPI

    func launch() async throws {
        guard !isRunning else { return }
        isRunning = true
        if var window = windowOnLaunch {
            nextID += 1
            window.id = nextID
            windowList.insert(window, at: 0)
        }
    }

    func activate() { activations += 1 }
    func reopen() async throws { isRunning = true; activations += 1 }
    func open(_ url: URL) { handedOff.append(url) }

    func windows() throws -> [SafariWindow] {
        guard isRunning else { return [] }
        return windowList.map {
            SafariWindow(id: $0.id, title: title(of: $0), tabCount: $0.tabs.count,
                         firstTabURL: $0.tabs.first?.url ?? "", isPrivate: $0.isPrivate)
        }
    }

    func tabs() throws -> [Int: WindowTabs] {
        Dictionary(uniqueKeysWithValues: windowList.map {
            ($0.id, WindowTabs(titles: $0.tabs.map(\.title), urls: $0.tabs.map(\.url), current: $0.current))
        })
    }

    func currentTab() throws -> SafariTab {
        guard let front = windowList.first else { throw SafariError.noWindows }
        return SafariTab(windowID: front.id, windowTitle: title(of: front), index: front.current + 1,
                         tabCount: front.tabs.count, url: front.tabs[front.current].url, isPrivate: front.isPrivate)
    }

    func bounds(windowID: Int) throws -> CGRect? { windowList[try index(windowID)].frame }
    func setBounds(_ rect: CGRect, windowID: Int) throws { windowList[try index(windowID)].frame = rect }
    func isFullScreen(windowID: Int) -> Bool { window(windowID)?.fullScreen ?? false }
    func setFullScreen(windowID: Int) {
        if let index = windowList.firstIndex(where: { $0.id == windowID }) { windowList[index].fullScreen = true }
    }

    func focus(windowID: Int) throws {
        let window = windowList.remove(at: try index(windowID))
        windowList.insert(window, at: 0)
    }

    func close(windowID: Int) throws { windowList.remove(at: try index(windowID)) }

    func openTab(url: String, windowID: Int) throws {
        let index = try index(windowID)
        windowList[index].tabs.append(Tab(title: url, url: url))
        windowList[index].current = windowList[index].tabs.count - 1
    }

    func setCurrentTabURL(_ url: String, windowID: Int) throws {
        let index = try index(windowID)
        windowList[index].tabs[windowList[index].current] = Tab(title: url, url: url)
    }

    func selectTab(index tab: Int, windowID: Int) throws {
        let index = try index(windowID)
        guard windowList[index].tabs.indices.contains(tab - 1) else { throw SafariError.script("no tab \(tab)") }
        windowList[index].current = tab - 1
    }

    func closeTab(index tab: Int, windowID: Int) throws {
        let index = try index(windowID)
        windowList[index].tabs.remove(at: tab - 1)
        if windowList[index].tabs.isEmpty {
            windowList.remove(at: index)
        } else {
            windowList[index].current = min(windowList[index].current, windowList[index].tabs.count - 1)
        }
    }

    func moveTab(index tab: Int, from source: Int, to target: Int) throws {
        let moved = windowList[try index(source)].tabs[tab - 1]
        try closeTab(index: tab, windowID: source)
        let targetIndex = try index(target)
        windowList[targetIndex].tabs.append(moved)
        windowList[targetIndex].current = windowList[targetIndex].tabs.count - 1
    }

    func openNewWindow(profile: String) throws {
        if profile == ProfileMatcher.privateProfile {
            addWindow(profile: nil, isPrivate: true, front: true)
        } else {
            guard profiles.contains(profile) else { throw SafariError.menuItemNotFound(profile) }
            addWindow(profile: profile, front: true)
        }
    }

    func moveCurrentTabToNewWindow() throws -> Bool {
        guard var front = windowList.first, front.tabs.count > 1 else { return false }
        let tab = front.tabs.remove(at: front.current)
        front.current = min(front.current, front.tabs.count - 1)
        windowList[0] = front
        addWindow(profile: front.profile, isPrivate: front.isPrivate, tabs: [tab], front: true)
        return true
    }

    func waitForNewWindow(excluding known: Set<Int>) async throws -> Int {
        // Let other queued work run here, as it could while the real Safari opens a window.
        await Task.yield()
        guard let window = windowList.first(where: { !known.contains($0.id) }) else { throw SafariError.timeout }
        return window.id
    }

    func detectProfiles() -> [String] { profiles }
    /// What AX reports as Safari's focused window.
    var focusedWindow: Int?
    func focusedWindowID() -> Int? { focusedWindow }
    func waitUntilActive() async {}
}
