import Foundation

/// One entry of the switcher HUD.
public struct HUDItem: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// Show the profile: its front-most window, or a new one if it has none.
        case profile(String)
        case window(id: Int)
    }

    public let target: Target
    public let title: String
    public let profile: String?
    /// Profiles: open windows of the profile. Windows: tabs in the window.
    public let count: Int

    public init(target: Target, title: String, profile: String?, count: Int) {
        self.target = target
        self.title = title
        self.profile = profile
        self.count = count
    }
}

/// Items and the selection, like ⌘⇥: the current item first, the next one selected.
public struct HUDState: Equatable, Sendable {
    public let items: [HUDItem]
    public private(set) var selection: Int

    public init(items: [HUDItem], selection: Int) {
        self.items = items
        self.selection = items.isEmpty ? 0 : min(max(selection, 0), items.count - 1)
    }

    public var selected: HUDItem? { items.indices.contains(selection) ? items[selection] : nil }

    /// Moves the selection, wrapping around.
    public mutating func move(by offset: Int) {
        guard !items.isEmpty else { return }
        selection = ((selection + offset) % items.count + items.count) % items.count
    }

    public mutating func select(_ index: Int) {
        if items.indices.contains(index) { selection = index }
    }

    /// One tile per profile: the current one (front window's) first, then the others in `profiles` order.
    public static func profiles(windows: [SafariWindow], profiles: [String]) -> HUDState {
        let profiles = profiles.filter { !$0.isEmpty }
        let current = windows.first.flatMap { ProfileMatcher.profile(ofTitle: $0.title, among: profiles) }
        let ordered = (current.map { [$0] } ?? []) + profiles.filter { $0 != current }
        let items = ordered.map { profile in
            HUDItem(
                target: .profile(profile), title: profile, profile: profile,
                count: windows.filter { ProfileMatcher.profile(ofTitle: $0.title, among: profiles) == profile }.count)
        }
        // Without a current profile, the first tile is already "another" profile.
        return HUDState(items: items, selection: current == nil ? 0 : 1)
    }

    /// One row per window, front to back; the second (previous) window selected.
    public static func windows(windows: [SafariWindow], profiles: [String]) -> HUDState {
        let items = windows.map { window in
            let profile = ProfileMatcher.profile(ofTitle: window.title, among: profiles)
            return HUDItem(
                target: .window(id: window.id),
                title: ProfileMatcher.pageTitle(ofTitle: window.title, profile: profile),
                profile: profile, count: window.tabCount)
        }
        return HUDState(items: items, selection: 1)
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
        /// Show the HUD with the selection moved by this many extra presses.
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
