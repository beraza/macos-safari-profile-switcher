import Foundation

/// One entry of the switcher HUD.
public struct HUDItem: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// Show the profile: its front-most window, or a new one if it has none.
        case profile(String)
        case window(id: Int)
    }

    public let target: Target
    /// The page title for a window (without the profile prefix), empty for a profile without windows.
    public let title: String
    public let profile: String?
    /// Tabs in the window (0 for a profile without windows).
    public let count: Int
    /// Tab titles, if listed (the window list shows them).
    public let tabs: [String]
    /// The window's current tab, 0-based.
    public let currentTab: Int

    public init(target: Target, title: String, profile: String?, count: Int, tabs: [String] = [], currentTab: Int = 0) {
        self.target = target
        self.title = title
        self.profile = profile
        self.count = count
        self.tabs = tabs
        self.currentTab = min(max(currentTab, 0), max(tabs.count - 1, 0))
    }
}

/// The tabs of a window, as Safari lists them.
public struct WindowTabs: Equatable, Sendable {
    public let titles: [String]
    /// Same order as `titles`; empty if not listed.
    public let urls: [String]
    /// 0-based.
    public let current: Int

    public init(titles: [String], urls: [String] = [], current: Int) {
        self.titles = titles
        self.urls = urls
        self.current = current
    }
}

/// The items of one profile in the HUD's profile layout (a column: the profile, then its windows).
public struct HUDGroup: Equatable, Sendable {
    /// `nil` for windows of no known profile.
    public let profile: String?
    public let items: Range<Int>
    public let windowCount: Int

    public init(profile: String?, items: Range<Int>, windowCount: Int) {
        self.profile = profile
        self.items = items
        self.windowCount = windowCount
    }
}

/// Items and the selection, like ⌘⇥: the current item first, the next one selected.
public struct HUDState: Equatable, Sendable {
    public enum Direction: Sendable {
        /// Next / previous profile (in the window list: next / previous window).
        case next, previous
        /// Window above / below within the profile (in the window list: the same as previous / next).
        case up, down
    }

    public let items: [HUDItem]
    /// Columns of the profile layout; empty for the plain window list.
    public let groups: [HUDGroup]
    public private(set) var selection: Int {
        didSet { tabSelection = selected?.currentTab ?? 0 }
    }
    /// The selected tab of the selected window (its current tab until moved).
    public private(set) var tabSelection: Int

    public init(items: [HUDItem], groups: [HUDGroup] = [], selection: Int) {
        self.items = items
        self.groups = groups
        self.selection = items.isEmpty ? 0 : min(max(selection, 0), items.count - 1)
        tabSelection = items.isEmpty ? 0 : items[self.selection].currentTab
    }

    public var selected: HUDItem? { items.indices.contains(selection) ? items[selection] : nil }

    /// The selected tab, if the selected window's tabs are listed.
    public var selectedTab: Int? { selected?.tabs.isEmpty == false ? tabSelection : nil }

    /// Selects the window with `id` (if listed) and its tab `tab`, clamped to the tabs it has.
    public mutating func select(windowID id: Int, tab: Int) {
        if let index = items.firstIndex(where: { $0.target == .window(id: id) }) { selection = index }
        if let tabs = selected?.tabs, !tabs.isEmpty { tabSelection = min(max(tab, 0), tabs.count - 1) }
    }

    /// Index of the group holding the selection.
    public var selectedGroup: Int? { groups.firstIndex { $0.items.contains(selection) } }

    /// Moves the selection, wrapping around.
    public mutating func move(by offset: Int) {
        guard !items.isEmpty else { return }
        selection = Self.wrap(selection + offset, count: items.count)
    }

    public mutating func step(_ direction: Direction) {
        guard let group = selectedGroup else {
            // The window list: up / down between windows, next / previous between the window's tabs.
            let forward = direction == .next || direction == .down
            if direction == .next || direction == .previous, let tabs = selected?.tabs, tabs.count > 1 {
                tabSelection = Self.wrap(tabSelection + (forward ? 1 : -1), count: tabs.count)
            } else {
                move(by: forward ? 1 : -1)
            }
            return
        }
        switch direction {
        case .next, .previous:
            // Like ⌘⇥ between apps: to the front-most window of the next profile.
            let target = Self.wrap(group + (direction == .next ? 1 : -1), count: groups.count)
            selection = groups[target].items.lowerBound
        case .up, .down:
            // Through the selected window's tabs, then on to the next (previous) window of the profile.
            let down = direction == .down
            if let tabs = selected?.tabs, !tabs.isEmpty, down ? tabSelection < tabs.count - 1 : tabSelection > 0 {
                tabSelection += down ? 1 : -1
                return
            }
            let range = groups[group].items
            selection = range.lowerBound + Self.wrap(selection - range.lowerBound + (down ? 1 : -1), count: range.count)
            if let tabs = selected?.tabs, !tabs.isEmpty { tabSelection = down ? 0 : tabs.count - 1 }
        }
    }

    /// Steps `count` times forward (positive) or back (negative), as the switch shortcut does: to the next
    /// profile in the profile layout, to the next window in the window list.
    public mutating func step(by count: Int) {
        let forward: Direction = groups.isEmpty ? .down : .next
        let back: Direction = groups.isEmpty ? .up : .previous
        for _ in 0..<abs(count) { step(count > 0 ? forward : back) }
    }

    public mutating func select(_ index: Int) {
        if items.indices.contains(index) { selection = index }
    }

    private static func wrap(_ index: Int, count: Int) -> Int {
        count == 0 ? 0 : (index % count + count) % count
    }

    /// A column per profile with its windows, front to back (a profile without windows gets one item that
    /// opens a new window). The current profile (the front window's) comes first, then the others in
    /// `profiles` order, then windows of no profile; the next profile's front window is selected.
    /// - Parameter tabs: tabs by window id; the selected window shows them and ⌥↑/⌥↓ go through them.
    public static func profiles(windows: [SafariWindow], profiles: [String], tabs: [Int: WindowTabs] = [:]) -> HUDState {
        let profiles = ProfileMatcher.cleaned(profiles)
        func profile(of window: SafariWindow) -> String? { ProfileMatcher.profile(of: window, among: profiles) }
        let current = windows.first.flatMap(profile(of:))
        var ordered: [String?] = (current.map { [$0] } ?? []) + profiles.filter { $0 != current }
        if windows.contains(where: { profile(of: $0) == nil }) { ordered.append(nil) }

        var items: [HUDItem] = []
        var groups: [HUDGroup] = []
        for group in ordered {
            let start = items.count
            let own = windows.filter { profile(of: $0) == group }
            if own.isEmpty, let group {
                items.append(HUDItem(target: .profile(group), title: "", profile: group, count: 0))
            }
            items += own.map { window in
                HUDItem(target: .window(id: window.id), title: pageTitle(window, profile: group),
                        profile: group, count: window.tabCount,
                        tabs: tabs[window.id]?.titles ?? [], currentTab: tabs[window.id]?.current ?? 0)
            }
            groups.append(HUDGroup(profile: group, items: start..<items.count, windowCount: own.count))
        }
        // Without a current profile, the first column is already "another" profile.
        let selected = groups.count > 1 && current != nil ? groups[1] : groups.first
        return HUDState(items: items, groups: groups, selection: selected?.items.lowerBound ?? 0)
    }

    /// One row per window, front to back, then a "new window" row for each profile without windows;
    /// the second (previous) window selected, or the first new window row if there is only one window.
    /// (Without windows, the first row.)
    /// - Parameter tabs: tabs by window id, shown in the window's row (left out: just the tab count).
    public static func windows(windows: [SafariWindow], profiles: [String], tabs: [Int: WindowTabs] = [:]) -> HUDState {
        let profiles = ProfileMatcher.cleaned(profiles)
        let items = windows.map { window in
            let profile = ProfileMatcher.profile(of: window, among: profiles)
            return HUDItem(
                target: .window(id: window.id), title: pageTitle(window, profile: profile),
                profile: profile, count: window.tabCount,
                tabs: tabs[window.id]?.titles ?? [], currentTab: tabs[window.id]?.current ?? 0)
        }
        let open = Set(items.compactMap(\.profile))
        let new = profiles.filter { !open.contains($0) }.map { profile in
            HUDItem(target: .profile(profile), title: "", profile: profile, count: 0)
        }
        // Without windows there's no current one to skip.
        return HUDState(items: items + new, selection: windows.isEmpty ? 0 : 1)
    }

    private static func pageTitle(_ window: SafariWindow, profile: String?) -> String {
        window.isPrivate ? window.title : ProfileMatcher.pageTitle(ofTitle: window.title, profile: profile)
    }
}

/// When the HUD appears, like ⌘⇥: a quick press and release switches right away; holding the modifier past
/// the delay (or pressing again) shows the HUD, and releasing the modifier confirms the selection.
/// The app feeds it shortcut presses and, while it is active, polls of the modifier state.
public struct HUDKeySession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The first press happened at `since`; `extraPresses` more came before the HUD appeared.
        case waiting(since: Double, extraPresses: Int)
        case shown
    }

    public enum Effect: Equatable, Sendable {
        case none
        /// Show the HUD with the selection moved by this many extra presses (negative: back).
        case show(extraPresses: Int)
        case moveSelection(Int)
        /// Released before the HUD appeared: switch as without a HUD.
        case switchNow
        /// Released while the HUD is shown: activate the selection.
        case confirm
    }

    public private(set) var phase: Phase = .idle
    /// Seconds the modifier has to be held before the HUD appears.
    public var delay: Double

    public init(delay: Double) {
        self.delay = delay
    }

    /// Whether the modifier state has to be polled.
    public var isActive: Bool { phase != .idle }

    /// A press of the switch shortcut at time `now` (seconds).
    public mutating func press(at now: Double) -> Effect {
        switch phase {
        case .idle:
            if delay <= 0 {
                phase = .shown
                return .show(extraPresses: 0)
            }
            phase = .waiting(since: now, extraPresses: 0)
            return .none
        case .waiting(_, let extra):
            phase = .shown
            return .show(extraPresses: extra + 1)
        case .shown:
            return .moveSelection(1)
        }
    }

    /// A press of the switch shortcut with Shift (going back, like ⌘⇧⇥); it only counts once a press of
    /// the switch shortcut has started the session.
    public mutating func pressBack(at now: Double) -> Effect {
        switch phase {
        case .idle:
            return .none
        case .waiting(_, let extra):
            phase = .shown
            return .show(extraPresses: extra - 1)
        case .shown:
            return .moveSelection(-1)
        }
    }

    /// A poll of whether the shortcut's modifiers are still held.
    public mutating func tick(modifiersHeld: Bool, at now: Double) -> Effect {
        switch phase {
        case .idle:
            return .none
        case .waiting(let since, let extra):
            if !modifiersHeld {
                phase = .idle
                return .switchNow
            }
            guard now - since >= delay else { return .none }
            phase = .shown
            return .show(extraPresses: extra)
        case .shown:
            guard !modifiersHeld else { return .none }
            phase = .idle
            return .confirm
        }
    }

    /// Cancelled, confirmed by a click, or the HUD couldn't be shown.
    public mutating func reset() {
        phase = .idle
    }
}
