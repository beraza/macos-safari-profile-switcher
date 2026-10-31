import AppKit
import ApplicationServices
import Carbon.OpenScripting
import SwitcherCore
import os

let log = Logger(subsystem: "com.djonny.SafariProfileSwitcher", category: "app")

enum SafariError: LocalizedError {
    case script(String)
    case notRunning
    case menuItemNotFound(String)
    case accessibilityDenied
    case timeout
    case notResponding
    case noWindows

    var errorDescription: String? {
        switch self {
        case .script(let message): "AppleScript: \(message)"
        case .notRunning: String(localized: "Safari is not running")
        case .menuItemNotFound(let profile):
            String(localized: "No “New Window” menu item for profile “\(profile)”")
        case .accessibilityDenied: String(localized: "No Accessibility permission")
        case .timeout: String(localized: "Safari did not open a new window in time")
        case .notResponding: String(localized: "Safari is not responding")
        case .noWindows: String(localized: "Safari has no open windows")
        }
    }
}

/// Talks to Safari: windows and tabs via AppleScript, menus and window raising via the Accessibility API.
/// AppleScript isn't thread-safe, so everything runs on the main actor.
@MainActor
enum SafariController {
    nonisolated static let bundleID = "com.apple.Safari"

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // MARK: - AppleScript library

    /// All AppleScript in one script, compiled once; Swift calls its handlers with parameters.
    static let librarySource = """
        on listWindows()
            with timeout of 5 seconds
                tell application "Safari"
                    set out to {}
                    repeat with w in windows
                        try
                            -- Closed windows linger as invisible ones (for "Reopen Last Closed Window"); skip them,
                            -- and windows without tabs: Safari's settings, a detached Web Inspector.
                            if (visible of w or miniaturized of w) and (count of tabs of w) > 0 then
                                set u to ""
                                try
                                    set u to URL of tab 1 of w
                                end try
                                if u is missing value then set u to ""
                                set end of out to {id of w, name of w, count of tabs of w, u}
                            end if
                        end try
                    end repeat
                    return out
                end tell
            end timeout
        end listWindows

        on listTabs()
            with timeout of 5 seconds
                tell application "Safari"
                    set out to {}
                    repeat with w in windows
                        try
                            if (visible of w or miniaturized of w) and (count of tabs of w) > 0 then
                                set end of out to {id of w, index of current tab of w, name of every tab of w, URL of every tab of w}
                            end if
                        end try
                    end repeat
                    return out
                end tell
            end timeout
        end listTabs

        on selectTab(wid, idx)
            with timeout of 5 seconds
                tell application "Safari" to set current tab of window id wid to tab idx of window id wid
            end timeout
        end selectTab

        on windowInfo(wid)
            with timeout of 5 seconds
                tell application "Safari"
                    set w to window id wid
                    return {name of w, bounds of w}
                end tell
            end timeout
        end windowInfo

        on focusWindow(wid)
            with timeout of 5 seconds
                tell application "Safari"
                    set w to window id wid
                    if miniaturized of w then set miniaturized of w to false
                    set index of w to 1
                    return {name of w, bounds of w}
                end tell
            end timeout
        end focusWindow

        on closeWindow(wid)
            with timeout of 5 seconds
                tell application "Safari" to close window id wid
            end timeout
        end closeWindow

        on setWindowBounds(wid, b)
            with timeout of 5 seconds
                tell application "Safari" to set bounds of window id wid to b
            end timeout
        end setWindowBounds

        on currentTabInfo()
            with timeout of 5 seconds
                tell application "Safari"
                    -- Closed windows linger as invisible ones; take the front-most visible window.
                    repeat with w in windows
                        set isVisible to false
                        try
                            set isVisible to visible of w and (count of tabs of w) > 0
                        end try
                        if isVisible then
                            set t to current tab of w
                            set u to URL of t
                            if u is missing value then set u to ""
                            return {id of w, name of w, index of t, count of tabs of w, u}
                        end if
                    end repeat
                    return {}
                end tell
            end timeout
        end currentTabInfo

        on openTab(wid, u)
            with timeout of 5 seconds
                tell application "Safari"
                    set w to window id wid
                    tell w to set t to make new tab at end of tabs with properties {URL:u}
                    set current tab of w to t
                end tell
            end timeout
        end openTab

        on setCurrentTabURL(wid, u)
            with timeout of 5 seconds
                tell application "Safari" to set URL of current tab of window id wid to u
            end timeout
        end setCurrentTabURL

        on closeTab(wid, idx)
            with timeout of 5 seconds
                tell application "Safari" to close tab idx of window id wid
            end timeout
        end closeTab

        on moveTab(fromWid, idx, toWid)
            with timeout of 5 seconds
                tell application "Safari"
                    move tab idx of window id fromWid to end of tabs of window id toWid
                    set w to window id toWid
                    set current tab of w to last tab of w
                end tell
            end timeout
        end moveTab

        on makeDocument(u)
            with timeout of 5 seconds
                tell application "Safari"
                    make new document with properties {URL:u}
                    return id of window 1
                end tell
            end timeout
        end makeDocument
        """

    private static var compiledLibrary: NSAppleScript?

    private static func library() throws -> NSAppleScript {
        if let compiledLibrary { return compiledLibrary }
        guard let script = NSAppleScript(source: librarySource) else {
            throw SafariError.script(String(localized: "could not compile"))
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { throw scriptError(error) }
        compiledLibrary = script
        return script
    }

    /// Calls a handler of the compiled library. Each handler gives up after 5 seconds if Safari hangs
    /// (instead of AppleScript's default 2 minutes, which would freeze the menu bar and the shortcuts).
    @discardableResult
    static func call(_ handler: String, _ arguments: NSAppleEventDescriptor...) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        // Handler names are case-insensitive and must be passed in lowercase.
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            list.insert(argument, at: offset + 1)
        }
        event.setDescriptor(list, forKeyword: keyDirectObject)
        var error: NSDictionary?
        let result = try library().executeAppleEvent(event, error: &error)
        if let error { throw scriptError(error) }
        return result
    }

    /// Compiles and runs `source` from scratch, as the app did before the library existed (self-test timing only).
    static func runUncompiled(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw SafariError.script("could not compile") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw scriptError(error) }
        return result
    }

    private static func scriptError(_ error: NSDictionary?) -> SafariError {
        switch error?[NSAppleScript.errorNumber] as? Int {
        case -1712: return .notResponding // errAETimeout
        case -600, -609: return .notRunning // procNotFound, connectionInvalid
        default: break
        }
        return .script(error?[NSAppleScript.errorMessage] as? String ?? "\(error ?? [:])")
    }

    // MARK: - Windows and tabs

    /// Profiles found by the last `detectProfiles()`; windows of none of them are Private Browsing ones.
    private static var realProfiles: [String] = []

    /// Browser windows, front-most first. Empty while Safari isn't running: AppleScript would launch it.
    static func windows() throws -> [SafariWindow] {
        guard runningApp != nil else { return [] }
        return parseWindows(try call("listWindows"))
    }

    static func parseWindows(_ list: NSAppleEventDescriptor) -> [SafariWindow] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { index in
            guard let item = list.atIndex(index), item.numberOfItems == 4,
                  let id = item.atIndex(1)?.int32Value,
                  let tabs = item.atIndex(3)?.int32Value
            else { return nil }
            let title = item.atIndex(2)?.stringValue ?? ""
            return SafariWindow(
                id: Int(id),
                title: title,
                tabCount: Int(tabs),
                firstTabURL: item.atIndex(4)?.stringValue ?? "",
                isPrivate: ProfileMatcher.isPrivate(title: title, realProfiles: realProfiles)
            )
        }
    }

    /// Tab titles and the current tab of each window, by window id.
    static func tabs() throws -> [Int: WindowTabs] {
        guard runningApp != nil else { return [:] }
        let list = try call("listTabs")
        guard list.numberOfItems > 0 else { return [:] }
        var result: [Int: WindowTabs] = [:]
        for index in 1...list.numberOfItems {
            guard let item = list.atIndex(index), item.numberOfItems == 4,
                  let id = item.atIndex(1)?.int32Value, let current = item.atIndex(2)?.int32Value,
                  let names = item.atIndex(3), let urls = item.atIndex(4)
            else { continue }
            func strings(_ list: NSAppleEventDescriptor) -> [String] {
                // A tab without a page has `missing value` as its URL: an empty string here.
                list.numberOfItems == 0 ? [] : (1...list.numberOfItems).map { list.atIndex($0)?.stringValue ?? "" }
            }
            result[Int(id)] = WindowTabs(titles: strings(names), urls: strings(urls), current: Int(current) - 1)
        }
        return result
    }

    /// Opens a new window with `url` (in the profile Safari picks) and returns its id.
    static func makeDocument(url: String) throws -> Int {
        Int(try call("makeDocument", NSAppleEventDescriptor(string: url)).int32Value)
    }

    /// Makes a tab (1-based) the window's current one.
    static func selectTab(index: Int, windowID: Int) throws {
        try call("selectTab", .int(windowID), .int(index))
    }

    /// The current tab of the front window.
    static func currentTab() throws -> SafariTab {
        let info = try call("currentTabInfo")
        guard info.numberOfItems == 5 else { throw SafariError.noWindows }
        let title = info.atIndex(2)?.stringValue ?? ""
        return SafariTab(
            windowID: Int(info.atIndex(1)?.int32Value ?? 0),
            windowTitle: title,
            index: Int(info.atIndex(3)?.int32Value ?? 0),
            tabCount: Int(info.atIndex(4)?.int32Value ?? 0),
            url: info.atIndex(5)?.stringValue ?? "",
            isPrivate: ProfileMatcher.isPrivate(title: title, realProfiles: realProfiles))
    }

    static func bounds(windowID: Int) throws -> CGRect? {
        rect(fromBounds: try call("windowInfo", .int(windowID)).atIndex(2))
    }

    static func setBounds(_ rect: CGRect, windowID: Int) throws {
        let bounds = NSAppleEventDescriptor.list()
        for (offset, value) in [rect.minX, rect.minY, rect.maxX, rect.maxY].enumerated() {
            bounds.insert(.int(Int(value.rounded())), at: offset + 1)
        }
        try call("setWindowBounds", .int(windowID), bounds)
    }

    static func focus(windowID: Int) throws {
        let info = try call("focusWindow", .int(windowID))
        // `set index` reorders windows but doesn't always move keyboard focus; raise via AX as well.
        guard let window = axWindow(title: info.atIndex(1)?.stringValue ?? "", frame: rect(fromBounds: info.atIndex(2)))
        else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func close(windowID: Int) throws {
        try call("closeWindow", .int(windowID))
    }

    /// Opens `url` in a new tab at the end of the window and makes it current.
    static func openTab(url: String, windowID: Int) throws {
        try call("openTab", .int(windowID), NSAppleEventDescriptor(string: url))
    }

    static func setCurrentTabURL(_ url: String, windowID: Int) throws {
        try call("setCurrentTabURL", .int(windowID), NSAppleEventDescriptor(string: url))
    }

    static func closeTab(index: Int, windowID: Int) throws {
        try call("closeTab", .int(windowID), .int(index))
    }

    /// Moves a tab (with its history) to the end of another window of the same profile and selects it.
    static func moveTab(index: Int, from source: Int, to target: Int) throws {
        try call("moveTab", .int(source), .int(index), .int(target))
    }

    /// Waits until a window not in `known` appears and returns its id (the front-most such window).
    static func waitForNewWindow(excluding known: Set<Int>, timeout: Duration = .seconds(3)) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = try windows().first(where: { !known.contains($0.id) }) {
                return window.id
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SafariError.timeout
    }

    /// AppleScript `bounds` ({left, top, right, bottom}, top-left origin like AX) as a rect.
    private static func rect(fromBounds descriptor: NSAppleEventDescriptor?) -> CGRect? {
        guard let descriptor, descriptor.numberOfItems == 4 else { return nil }
        let values = (1...4).compactMap { descriptor.atIndex($0)?.int32Value }.map(CGFloat.init)
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
    }

    // MARK: - Windows (Accessibility)

    /// The AX window for an AppleScript window id. Titles can repeat ("Work — Favorites"), so the frame
    /// is compared too; falls back to the front-most window with the title.
    static func axWindow(id: Int) -> AXUIElement? {
        guard let info = try? call("windowInfo", .int(id)) else { return nil }
        return axWindow(title: info.atIndex(1)?.stringValue ?? "", frame: rect(fromBounds: info.atIndex(2)))
    }

    private static func axWindow(title: String, frame: CGRect?) -> AXUIElement? {
        guard let app = axApp() else { return nil }
        let candidates = axChildren(app, kAXWindowsAttribute).filter { axString($0, kAXTitleAttribute) == title }
        return candidates.first { candidate in
            guard let frame, let candidateFrame = axFrame(candidate) else { return false }
            return abs(candidateFrame.minX - frame.minX) <= 1 && abs(candidateFrame.minY - frame.minY) <= 1
                && abs(candidateFrame.width - frame.width) <= 1 && abs(candidateFrame.height - frame.height) <= 1
        } ?? candidates.first
    }

    /// The AppleScript id of Safari's focused window (the last one used, also while Safari is in the
    /// background): its AX title and frame matched against the AppleScript windows.
    static func focusedWindowID() -> Int? {
        guard let app = axApp(), let focused = axElement(app, kAXFocusedWindowAttribute),
              let title = axString(focused, kAXTitleAttribute)
        else { return nil }
        let candidates = ((try? windows()) ?? []).filter { $0.title == title }
        guard candidates.count > 1, let frame = axFrame(focused) else { return candidates.first?.id }
        return candidates.first { candidate in
            guard let bounds = try? bounds(windowID: candidate.id) else { return false }
            return abs(bounds.minX - frame.minX) <= 1 && abs(bounds.minY - frame.minY) <= 1
                && abs(bounds.width - frame.width) <= 1 && abs(bounds.height - frame.height) <= 1
        }?.id ?? candidates.first?.id
    }

    static func isFullScreen(windowID: Int) -> Bool {
        axWindow(id: windowID).flatMap { axBool($0, "AXFullScreen") } ?? false
    }

    static func setFullScreen(windowID: Int) {
        guard let window = axWindow(id: windowID) else { return }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
    }

    // MARK: - Menu (Accessibility)

    /// Opens a new window of `profile` (or a Private Browsing one) by pressing its item in Safari's File menu.
    static func openNewWindow(profile: String) throws {
        guard AXIsProcessTrusted() else { throw SafariError.accessibilityDenied }
        guard let fileMenu = barMenu(at: 2) else { throw SafariError.notRunning }
        let items = menuItems(in: fileMenu)
        // Only an exact «Profile» match: a substring could hit another profile ("Work" in «Work Old») or any item.
        let item = profile == ProfileMatcher.privateProfile
            ? items.first { newPrivateWindowTitles.contains($0.title) && $0.enabled }
            : items.first { quotedName(in: $0.title) == profile && $0.enabled }
        guard let item else { throw SafariError.menuItemNotFound(profile) }
        try press(item)
    }

    /// Presses Window → Move Tab to New Window. Returns `false` if the item isn't there (or is disabled).
    static func moveCurrentTabToNewWindow() throws -> Bool {
        guard AXIsProcessTrusted() else { throw SafariError.accessibilityDenied }
        guard let windowMenu = barMenu(fromEnd: 2) else { throw SafariError.notRunning }
        let titles = moveTabTitles
        guard let item = menuItems(in: windowMenu).first(where: { titles.contains($0.title) && $0.enabled }) else {
            return false
        }
        try press(item)
        return true
    }

    private static let moveTabTitles = menuTitles(english: "Move Tab to New Window", key: "869.title")
    private static let newPrivateWindowTitles = menuTitles(english: "New Private Window", key: "CV2-YC-yYw.title")

    /// A menu item title in English and in the language Safari runs in (from Safari's own MainMenu.strings).
    private static func menuTitles(english: String, key: String) -> Set<String> {
        var titles: Set<String> = [english]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let safari = Bundle(url: url),
           let language = Bundle.preferredLocalizations(from: safari.localizations).first,
           let path = safari.path(forResource: "MainMenu", ofType: "strings", inDirectory: nil, forLocalization: language),
           let strings = NSDictionary(contentsOfFile: path),
           let title = strings[key] as? String {
            titles.insert(title)
        }
        return titles
    }

    /// Profile names found in the File menu ("New Window «Profile»" items), falling back to window title prefixes.
    static func detectProfiles() -> [String] {
        var names: [String] = []
        if AXIsProcessTrusted(), let fileMenu = barMenu(at: 2) {
            names = menuItems(in: fileMenu).compactMap { quotedName(in: $0.title) }
        }
        if names.isEmpty, let windows = try? windows() {
            // Only titles that have a profile prefix; otherwise the whole page title would pass for a profile.
            names = windows.compactMap { window in
                window.title.range(of: ProfileMatcher.separator).map { String(window.title[..<$0.lowerBound]) }
            }
        }
        realProfiles = ProfileMatcher.cleaned(names)
        return realProfiles
    }

    struct MenuItem {
        let element: AXUIElement
        let title: String
        let enabled: Bool
        let depth: Int
    }

    private static func press(_ item: MenuItem) throws {
        let status = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        guard status == .success else { throw SafariError.script("AXPress: \(status.rawValue)") }
    }

    /// Menu bar order: Apple, Safari, File, …, Window, Help (index-based so it works in any language).
    private static func barItems() -> [AXUIElement] {
        guard let app = axApp(), let menuBar = axElement(app, kAXMenuBarAttribute) else { return [] }
        return axChildren(menuBar, kAXChildrenAttribute)
    }

    private static func barMenu(at index: Int) -> AXUIElement? {
        let items = barItems()
        guard items.indices.contains(index) else { return nil }
        return axChildren(items[index], kAXChildrenAttribute).first
    }

    /// `fromEnd: 1` is Help, `2` is Window (the Develop menu is optional, so count from the end).
    private static func barMenu(fromEnd offset: Int) -> AXUIElement? {
        let items = barItems()
        guard items.count >= offset + 3 else { return nil }
        return axChildren(items[items.count - offset], kAXChildrenAttribute).first
    }

    /// Depth-first list of all menu items, including submenus.
    private static func menuItems(in menu: AXUIElement, depth: Int = 0) -> [MenuItem] {
        axChildren(menu, kAXChildrenAttribute).flatMap { element -> [MenuItem] in
            let item = MenuItem(
                element: element,
                title: axString(element, kAXTitleAttribute) ?? "",
                enabled: axBool(element, kAXEnabledAttribute) ?? false,
                depth: depth
            )
            let submenus = axChildren(element, kAXChildrenAttribute)
            return [item] + submenus.flatMap { menuItems(in: $0, depth: depth + 1) }
        }
    }

    /// Text inside «…», “…” or "…" quotes, as Safari writes profile names in menu titles.
    nonisolated static func quotedName(in title: String) -> String? {
        let pattern = #"[«“"‘]([^»”"’]+)[»”"’]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title)
        else { return nil }
        return String(title[range])
    }

    // MARK: - Diagnostics

    /// What the app sees of Safari, for bug reports. Private Browsing windows are listed without their
    /// titles and addresses: the file stays on disk, and private browsing shouldn't leave traces there.
    static func diagnostics() -> String {
        var lines = ["Accessibility: \(AXIsProcessTrusted())"]
        let profiles = detectProfiles()
        func shown(_ title: String) -> String {
            ProfileMatcher.isPrivate(title: title, realProfiles: profiles) ? "<private window>" : title
        }
        do {
            lines.append("AppleScript windows (front first):")
            for window in try windows() {
                lines.append(window.isPrivate ? "  id=\(window.id) tabs=\(window.tabCount) private"
                    : "  id=\(window.id) tabs=\(window.tabCount) url=\(window.firstTabURL) title=\(window.title)")
            }
        } catch {
            lines.append("  error: \(error.localizedDescription)")
        }
        if let app = axApp() {
            lines.append("AX windows:")
            for window in axChildren(app, kAXWindowsAttribute) {
                let frame = axFrame(window).map { "\($0)" } ?? "?"
                lines.append("  \(shown(axString(window, kAXTitleAttribute) ?? "?")) frame=\(frame)")
            }
        }
        for (name, menu) in [("File", barMenu(at: 2)), ("Window", barMenu(fromEnd: 2))] {
            guard let menu else { continue }
            lines.append("\(name) menu:")
            for item in menuItems(in: menu) {
                let indent = String(repeating: "  ", count: item.depth + 1)
                lines.append("\(indent)\(item.title.isEmpty ? "—" : item.title)\(item.enabled ? "" : " (disabled)")")
            }
        }
        lines.append("Move Tab titles: \(moveTabTitles.sorted())")
        lines.append("New Private Window titles: \(newPrivateWindowTitles.sorted())")
        lines.append("Detected profiles: \(profiles)")
        return lines.joined(separator: "\n")
    }

    /// Writes `diagnostics()` to ~/Library/Logs/SafariProfileSwitcher/diagnostics.txt.
    static func writeDiagnostics() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SafariProfileSwitcher")
        let file = directory.appendingPathComponent("diagnostics.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try diagnostics().write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - AX helpers

    static func axApp() -> AXUIElement? {
        runningApp.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        axValue(element, attribute) as? [AXUIElement] ?? []
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axValue(element, attribute) as? String
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        axValue(element, attribute) as? Bool
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = axValue(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

extension NSAppleEventDescriptor {
    static func int(_ value: Int) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(int32: Int32(value))
    }
}
