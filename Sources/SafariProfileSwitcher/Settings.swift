import AppKit
import Carbon.HIToolbox
import SwiftUI
import SwitcherCore

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value.
    var modifiers: UInt
    var keyLabel: String

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
        self.keyLabel = keyLabel
    }

    /// The label is only for display; two shortcuts are the same if they press the same keys.
    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Has a modifier besides Shift: a plain key (or Shift+key) as a global shortcut would swallow typing.
    var isUsable: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

    /// Modifiers that have to stay held for the HUD to stay open (Shift is used to go back).
    var holdFlags: NSEvent.ModifierFlags { flags.subtracting(.shift) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayString: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    private static let specialKeys: [Int: String] = [
        kVK_Tab: "⇥", kVK_Space: "Space", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_Grave: "`", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func label(for event: NSEvent) -> String {
        specialKeys[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}

extension ShortcutAction {
    var title: String {
        switch self {
        case .switchProfile: String(localized: "Switch profile")
        case .moveTabToOtherProfile: String(localized: "Move tab to the next profile")
        case .moveWindowToOtherProfile: String(localized: "Move window to the next profile")
        case .searchTabs: String(localized: "Search tabs in all profiles")
        case .detachTab: String(localized: "Move tab to a separate window")
        case .attachTab: String(localized: "Move tab back to the main window")
        case .hudNext: String(localized: "Switcher: next profile")
        case .hudPrevious: String(localized: "Switcher: previous profile")
        case .hudUp: String(localized: "Switcher: window above")
        case .hudDown: String(localized: "Switcher: window below")
        case .hudCloseTab: String(localized: "Switcher: close the tab (press twice)")
        case .hudCloseWindow: String(localized: "Switcher: close the window (press twice)")
        case .hudMoveTab: String(localized: "Switcher: move the tab to the next profile")
        case .hudMoveWindow: String(localized: "Switcher: move the window to the next profile")
        case .hudDetachTab: String(localized: "Switcher: move the tab to a separate window")
        case .hudCancel: String(localized: "Switcher: cancel")
        case .switchBack: String(localized: "Switcher: back")
        }
    }

    /// ⌥ is the profile modifier: ⌥⇥ switches, and while the switcher is open ⌥ + arrows move in it
    /// (⌥⇧⇥ goes back). ⌃⌥ + arrows act on the tab (⌃ as in Safari's ⌃⇥ for tabs). Not ⌥⇧ + arrows:
    /// in text fields those select by word and paragraph, and the shortcuts would take that away in Safari.
    var defaultShortcut: Shortcut? {
        switch self {
        case .switchProfile: Shortcut(keyCode: kVK_Tab, modifiers: .option, keyLabel: "⇥")
        case .moveTabToOtherProfile: Shortcut(keyCode: kVK_RightArrow, modifiers: [.control, .option], keyLabel: "→")
        case .moveWindowToOtherProfile:
            Shortcut(keyCode: kVK_RightArrow, modifiers: [.control, .option, .shift], keyLabel: "→")
        case .searchTabs: Shortcut(keyCode: kVK_ANSI_F, modifiers: [.control, .option], keyLabel: "F")
        case .detachTab: Shortcut(keyCode: kVK_UpArrow, modifiers: [.control, .option], keyLabel: "↑")
        case .attachTab: Shortcut(keyCode: kVK_DownArrow, modifiers: [.control, .option], keyLabel: "↓")
        case .hudNext: Shortcut(keyCode: kVK_RightArrow, modifiers: .option, keyLabel: "→")
        case .hudPrevious: Shortcut(keyCode: kVK_LeftArrow, modifiers: .option, keyLabel: "←")
        case .hudUp: Shortcut(keyCode: kVK_UpArrow, modifiers: .option, keyLabel: "↑")
        case .hudDown: Shortcut(keyCode: kVK_DownArrow, modifiers: .option, keyLabel: "↓")
        // As in Safari: W for the tab, ⇧W for the window.
        case .hudCloseTab: Shortcut(keyCode: kVK_ANSI_W, modifiers: .option, keyLabel: "W")
        case .hudCloseWindow: Shortcut(keyCode: kVK_ANSI_W, modifiers: [.option, .shift], keyLabel: "W")
        case .hudMoveTab: Shortcut(keyCode: kVK_ANSI_M, modifiers: .option, keyLabel: "M")
        case .hudMoveWindow: Shortcut(keyCode: kVK_ANSI_M, modifiers: [.option, .shift], keyLabel: "M")
        case .hudDetachTab: Shortcut(keyCode: kVK_ANSI_D, modifiers: .option, keyLabel: "D")
        case .hudCancel: Shortcut(keyCode: kVK_Escape, modifiers: .option, keyLabel: "⎋")
        case .switchBack: nil
        }
    }

    /// The switch shortcut with Shift added, if it has no Shift yet.
    static func switchBack(for shortcut: Shortcut?) -> Shortcut? {
        guard let shortcut, !shortcut.flags.contains(.shift) else { return nil }
        return Shortcut(keyCode: Int(shortcut.keyCode), modifiers: shortcut.flags.union(.shift), keyLabel: shortcut.keyLabel)
    }

    static var defaultBindings: [ShortcutAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } })
    }
}

/// What the switch shortcut does when Safari isn't the front app.
enum OutsideSafariAction: String, CaseIterable, Identifiable {
    case showSwitcher, activateSafari, switchProfile, passThrough

    var id: Self { self }

    var title: String {
        switch self {
        case .showSwitcher: String(localized: "Show the switcher (a quick press activates Safari)")
        case .activateSafari: String(localized: "Activate Safari")
        case .switchProfile: String(localized: "Activate Safari and switch profile")
        case .passThrough: String(localized: "Nothing (leave the shortcut to other apps)")
        }
    }
}

/// Modifiers for the numbered profile shortcuts (with 1…9: the profile at that place in the switching list).
enum NumberModifier: String, CaseIterable, Identifiable {
    case off, option, controlOption, optionCommand

    var id: Self { self }

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .off: nil
        case .option: .option
        case .controlOption: [.control, .option]
        case .optionCommand: [.option, .command]
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .option: "⌥1 … ⌥9"
        case .controlOption: "⌃⌥1 … ⌃⌥9"
        case .optionCommand: "⌥⌘1 … ⌥⌘9"
        }
    }

    /// The shortcut for profile `number` (1…9).
    func shortcut(_ number: Int) -> Shortcut? {
        guard let flags, (1...9).contains(number) else { return nil }
        let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return Shortcut(keyCode: keyCodes[number - 1], modifiers: flags, keyLabel: String(number))
    }
}

/// What the switcher HUD lists.
enum HUDMode: String, CaseIterable, Identifiable {
    case off, profiles, windows

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .profiles: String(localized: "Profiles and their windows")
        case .windows: String(localized: "Windows")
        }
    }
}

/// What the menu bar item shows.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// The app's icon only.
    case icon
    /// The front Safari window's profile as a colored badge.
    case badge
    /// The badge and the profile's name.
    case badgeAndName

    var id: Self { self }

    var title: String {
        switch self {
        case .icon: String(localized: "App icon")
        case .badge: String(localized: "Profile badge")
        case .badgeAndName: String(localized: "Profile badge and name")
        }
    }
}

/// Badge colors, like the ones Safari offers for profiles.
enum ProfileColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, graphite

    var id: Self { self }

    var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .graphite: NSColor(white: 0.32, alpha: 1)
        }
    }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .teal: String(localized: "Teal")
        case .graphite: String(localized: "Graphite")
        }
    }
}

extension ProfileMatcher {
    /// The name to show for a profile (Private Browsing has no name of its own).
    static func displayName(_ profile: String) -> String {
        profile == privateProfile ? String(localized: "Private Browsing") : profile
    }
}

@MainActor
final class AppSettings: ObservableObject {
    /// `defaultLinkProfile` value: hand links no rule matches to Safari, which applies its own
    /// "Open links in profile" website setting.
    static let safariDecides = "#safari"

    private let defaults: UserDefaults

    /// Profiles the switch shortcut goes through, in order (two or more to switch).
    @Published var switchProfiles: [String] { didSet { defaults.set(switchProfiles, forKey: "switchProfiles") } }
    /// Effective bindings; an action without an entry is disabled.
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] { didSet { saveShortcuts() } }
    @Published var closeEmptyWindow: Bool { didSet { defaults.set(closeEmptyWindow, forKey: "closeEmptyWindow") } }
    @Published var outsideSafariAction: OutsideSafariAction {
        didSet { defaults.set(outsideSafariAction.rawValue, forKey: "outsideSafariAction") }
    }
    /// Put a newly opened window of the other profile where the current window is.
    @Published var newWindowInPlace: Bool { didSet { defaults.set(newWindowInPlace, forKey: "newWindowInPlace") } }
    /// If the current window is full screen, make the new one full screen too.
    @Published var matchFullScreen: Bool { didSet { defaults.set(matchFullScreen, forKey: "matchFullScreen") } }
    /// Also move an existing window of the other profile onto the current window's frame.
    @Published var alignExistingWindows: Bool {
        didSet { defaults.set(alignExistingWindows, forKey: "alignExistingWindows") }
    }
    /// Copy the tab to the other profile instead of moving it.
    @Published var keepSourceTab: Bool { didSet { defaults.set(keepSourceTab, forKey: "keepSourceTab") } }
    @Published var hudMode: HUDMode { didSet { defaults.set(hudMode.rawValue, forKey: "hudMode") } }
    /// How long the modifier has to be held before the HUD appears, in seconds.
    @Published var hudDelay: Double { didSet { defaults.set(hudDelay, forKey: "hudDelay") } }
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// Badge color per profile; missing ones get a color by their position.
    @Published var profileColors: [String: String] { didSet { defaults.set(profileColors, forKey: "profileColors") } }
    /// ⌥1…⌥9: go to the profile at that place in the switching list.
    @Published var profileNumberModifier: NumberModifier {
        didSet { defaults.set(profileNumberModifier.rawValue, forKey: "profileNumberModifier") }
    }
    /// ⌃⌥1…⌃⌥9: move the tab to that profile.
    @Published var moveTabNumberModifier: NumberModifier {
        didSet { defaults.set(moveTabNumberModifier.rawValue, forKey: "moveTabNumberModifier") }
    }
    /// Link rules, first match wins.
    @Published var linkRules: [LinkRule] {
        didSet { defaults.set(try? JSONEncoder().encode(linkRules), forKey: "linkRules") }
    }
    /// Profile for links no rule matches; empty means "ask", `safariDecides` leaves it to Safari.
    @Published var defaultLinkProfile: String { didSet { defaults.set(defaultLinkProfile, forKey: "defaultLinkProfile") } }
    /// Open the link inside redirect wrappers (Outlook Safe Links, Facebook, Google, VK) instead of the wrapper.
    @Published var unwrapRedirects: Bool { didSet { defaults.set(unwrapRedirects, forKey: "unwrapRedirects") } }
    /// Remove utm_* and similar parameters from opened links.
    @Published var stripTrackingParams: Bool {
        didSet { defaults.set(stripTrackingParams, forKey: "stripTrackingParams") }
    }
    /// Window a detached tab came from, by the id of the window it was moved into. Kept across restarts of
    /// this app; cleared when Safari quits, since window ids start over then.
    @Published var detachedFrom: [Int: Int] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: detachedFrom.map { (String($0.key), $0.value) }),
                         forKey: "detachedFrom")
        }
    }
    /// Menu bar text per profile; the first letter of the name if missing.
    @Published var profileBadges: [String: String] { didSet { defaults.set(profileBadges, forKey: "profileBadges") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Blank names (e.g. a stray "\t" saved by an older text field) count as unset and get re-detected.
        switchProfiles = ProfileMatcher.cleaned(
            (defaults.stringArray(forKey: "switchProfiles")
                // Before more than two profiles: a first and a second one.
                ?? ["firstProfile", "secondProfile"].compactMap { defaults.string(forKey: $0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        shortcuts = Self.loadShortcuts(from: defaults)
        closeEmptyWindow = defaults.object(forKey: "closeEmptyWindow") as? Bool ?? true
        outsideSafariAction = defaults.string(forKey: "outsideSafariAction").flatMap(OutsideSafariAction.init)
            ?? .showSwitcher
        newWindowInPlace = defaults.object(forKey: "newWindowInPlace") as? Bool ?? true
        matchFullScreen = defaults.object(forKey: "matchFullScreen") as? Bool ?? true
        alignExistingWindows = defaults.object(forKey: "alignExistingWindows") as? Bool ?? false
        keepSourceTab = defaults.object(forKey: "keepSourceTab") as? Bool ?? false
        hudMode = defaults.string(forKey: "hudMode").flatMap(HUDMode.init) ?? .profiles
        hudDelay = defaults.object(forKey: "hudDelay") as? Double ?? 0.2
        menuBarStyle = defaults.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init)
            // Before the styles: a switch for the profile badge.
            ?? (defaults.object(forKey: "showProfileIndicator") as? Bool == false ? .icon : .badge)
        profileColors = defaults.dictionary(forKey: "profileColors") as? [String: String] ?? [:]
        profileNumberModifier = defaults.string(forKey: "profileNumberModifier").flatMap(NumberModifier.init) ?? .option
        moveTabNumberModifier = defaults.string(forKey: "moveTabNumberModifier").flatMap(NumberModifier.init)
            ?? .controlOption
        profileBadges = defaults.dictionary(forKey: "profileBadges") as? [String: String] ?? [:]
        linkRules = defaults.data(forKey: "linkRules").flatMap { try? JSONDecoder().decode([LinkRule].self, from: $0) } ?? []
        defaultLinkProfile = defaults.string(forKey: "defaultLinkProfile") ?? Self.safariDecides
        stripTrackingParams = defaults.object(forKey: "stripTrackingParams") as? Bool ?? true
        unwrapRedirects = defaults.object(forKey: "unwrapRedirects") as? Bool ?? true
        detachedFrom = (defaults.dictionary(forKey: "detachedFrom") as? [String: Int] ?? [:])
            .reduce(into: [:]) { result, entry in if let key = Int(entry.key) { result[key] = entry.value } }
    }

    /// Adds a rule for `host` (without "www.") or changes the profile of an existing one.
    func remember(host: String, profile: String) {
        let pattern = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let index = linkRules.firstIndex(where: { $0.pattern == pattern && $0.sourceApp.isEmpty }) {
            linkRules[index].profile = profile
        } else {
            linkRules.append(LinkRule(pattern: pattern, profile: profile))
        }
    }

    /// Profiles the settings refer to: the switching list, link rules and the default link profile.
    var usedProfiles: [String] {
        ProfileMatcher.cleaned(switchProfiles + linkRules.filter { $0.targetApp.isEmpty }.map(\.profile) + [defaultLinkProfile])
            .filter { $0 != Self.safariDecides }
    }

    /// Adds `profile` to the end of the switching list, or removes it.
    func setSwitching(_ profile: String, _ included: Bool) {
        switchProfiles.removeAll { $0 == profile }
        if included { switchProfiles.append(profile) }
    }

    /// Moves a profile of the switching list up (-1) or down (+1).
    func moveSwitching(_ profile: String, by offset: Int) {
        guard let index = switchProfiles.firstIndex(of: profile),
              switchProfiles.indices.contains(index + offset)
        else { return }
        switchProfiles.swapAt(index, index + offset)
    }

    /// Badge text: custom, or the first letter; empty for Private Browsing, which shows a symbol instead.
    func badge(for profile: String) -> String {
        let custom = profileBadges[profile]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !custom.isEmpty || profile == ProfileMatcher.privateProfile { return custom }
        return String(profile.prefix(1)).uppercased()
    }

    /// The badge color: chosen, graphite for Private Browsing, else by the profile's place in `profiles`.
    func color(for profile: String, among profiles: [String]) -> ProfileColor {
        if let chosen = profileColors[profile].flatMap(ProfileColor.init) { return chosen }
        if profile == ProfileMatcher.privateProfile { return .graphite }
        let palette = ProfileColor.allCases.filter { $0 != .graphite }
        let index = profiles.filter { $0 != ProfileMatcher.privateProfile }.firstIndex(of: profile)
            ?? abs(profile.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[index % palette.count]
    }

    /// Binds `shortcut` to `action` (`nil` disables it), resolving conflicts.
    /// - Returns: another action whose shortcut changed because of the conflict.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutAction? {
        var bindings = shortcuts
        let changed = ShortcutConflicts.assign(shortcut, to: action, in: &bindings)
        shortcuts = bindings
        return changed
    }

    // MARK: - Shortcut storage

    /// Stored as differences from the defaults, so actions added later get their default shortcut.
    struct StoredShortcuts: Codable {
        var custom: [String: Shortcut] = [:]
        var disabled: [String] = []

        /// The defaults with these differences; unknown actions and shortcuts without a modifier are ignored.
        var bindings: [ShortcutAction: Shortcut] {
            var bindings = ShortcutAction.defaultBindings
            for (name, shortcut) in custom {
                if let action = ShortcutAction(rawValue: name), action.isConfigurable, shortcut.isUsable {
                    bindings[action] = shortcut
                }
            }
            for name in disabled {
                if let action = ShortcutAction(rawValue: name) { bindings[action] = nil }
            }
            return bindings
        }
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [ShortcutAction: Shortcut] {
        var bindings = ShortcutAction.defaultBindings
        if let data = defaults.data(forKey: "shortcuts"),
           let stored = try? JSONDecoder().decode(StoredShortcuts.self, from: data) {
            bindings = stored.bindings
        } else if let data = defaults.data(forKey: "shortcut"),
                  let legacy = try? JSONDecoder().decode(Shortcut.self, from: data) {
            // Before per-action shortcuts there was only the switch shortcut.
            ShortcutConflicts.assign(legacy, to: .switchProfile, in: &bindings)
        }
        return bindings
    }

    private func saveShortcuts() {
        defaults.set(try? JSONEncoder().encode(storedShortcuts), forKey: "shortcuts")
        defaults.removeObject(forKey: "shortcut")
    }

    private var storedShortcuts: StoredShortcuts {
        var stored = StoredShortcuts()
        for action in ShortcutAction.allCases {
            switch (shortcuts[action], action.defaultShortcut) {
            case (nil, nil): break
            case (nil, _?): stored.disabled.append(action.rawValue)
            case (let shortcut?, let fallback):
                if shortcut != fallback || shortcut.keyLabel != fallback?.keyLabel {
                    stored.custom[action.rawValue] = shortcut
                }
            }
        }
        return stored
    }

    // MARK: - Export and import

    /// What a user sets, for a file to back up or move to another Mac (window bookkeeping stays out).
    /// Every field is optional, so a file from an older or newer version imports what it has.
    struct Backup: Codable {
        var app = "SafariProfileSwitcher"
        var version: Int? = 1
        var switchProfiles: [String]?
        var shortcuts: StoredShortcuts?
        var profileNumberModifier: String?
        var moveTabNumberModifier: String?
        var closeEmptyWindow: Bool?
        var outsideSafariAction: String?
        var newWindowInPlace: Bool?
        var matchFullScreen: Bool?
        var alignExistingWindows: Bool?
        var keepSourceTab: Bool?
        var hudMode: String?
        var hudDelay: Double?
        var menuBarStyle: String?
        var profileColors: [String: String]?
        var profileBadges: [String: String]?
        var linkRules: [LinkRule]?
        var defaultLinkProfile: String?
        var unwrapRedirects: Bool?
        var stripTrackingParams: Bool?
    }

    struct ImportError: LocalizedError {
        var errorDescription: String? { String(localized: "This isn't a settings file of Safari Profile Switcher") }
    }

    func exportData() throws -> Data {
        let backup = Backup(
            switchProfiles: switchProfiles, shortcuts: storedShortcuts,
            profileNumberModifier: profileNumberModifier.rawValue, moveTabNumberModifier: moveTabNumberModifier.rawValue,
            closeEmptyWindow: closeEmptyWindow, outsideSafariAction: outsideSafariAction.rawValue,
            newWindowInPlace: newWindowInPlace, matchFullScreen: matchFullScreen,
            alignExistingWindows: alignExistingWindows, keepSourceTab: keepSourceTab, hudMode: hudMode.rawValue,
            hudDelay: hudDelay, menuBarStyle: menuBarStyle.rawValue, profileColors: profileColors,
            profileBadges: profileBadges, linkRules: linkRules, defaultLinkProfile: defaultLinkProfile,
            unwrapRedirects: unwrapRedirects, stripTrackingParams: stripTrackingParams)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Applies a file from `exportData()`. Values are checked as they would be in the settings window:
    /// shortcuts need a modifier, badges are cut to 4 characters, the delay stays in its range.
    func importData(_ data: Data) throws {
        guard let backup = try? JSONDecoder().decode(Backup.self, from: data), backup.app == "SafariProfileSwitcher"
        else { throw ImportError() }
        if let value = backup.switchProfiles {
            switchProfiles = ProfileMatcher.cleaned(value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        if let value = backup.shortcuts { shortcuts = value.bindings }
        if let value = backup.profileNumberModifier.flatMap(NumberModifier.init) { profileNumberModifier = value }
        if let value = backup.moveTabNumberModifier.flatMap(NumberModifier.init) { moveTabNumberModifier = value }
        if let value = backup.closeEmptyWindow { closeEmptyWindow = value }
        if let value = backup.outsideSafariAction.flatMap(OutsideSafariAction.init) { outsideSafariAction = value }
        if let value = backup.newWindowInPlace { newWindowInPlace = value }
        if let value = backup.matchFullScreen { matchFullScreen = value }
        if let value = backup.alignExistingWindows { alignExistingWindows = value }
        if let value = backup.keepSourceTab { keepSourceTab = value }
        if let value = backup.hudMode.flatMap(HUDMode.init) { hudMode = value }
        if let value = backup.hudDelay, value.isFinite { hudDelay = min(max(value, 0), 0.6) }
        if let value = backup.menuBarStyle.flatMap(MenuBarStyle.init) { menuBarStyle = value }
        if let value = backup.profileColors { profileColors = value.filter { ProfileColor(rawValue: $0.value) != nil } }
        if let value = backup.profileBadges { profileBadges = value.mapValues { String($0.prefix(4)) } }
        if let value = backup.linkRules { linkRules = value }
        if let value = backup.defaultLinkProfile { defaultLinkProfile = value }
        if let value = backup.unwrapRedirects { unwrapRedirects = value }
        if let value = backup.stripTrackingParams { stripTrackingParams = value }
    }
}

/// Button that records a key combination. Esc cancels recording (⌥⎋ and other combos with Esc are recorded).
struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let onChange: (Shortcut) -> Void
    var onRecordingChange: (Bool) -> Void = { _ in }
    @State private var monitor: Any?

    var body: some View {
        Button(monitor != nil ? String(localized: "Press keys…")
               : shortcut?.displayString ?? String(localized: "Off")) {
            monitor == nil ? start() : stop()
        }
        .frame(minWidth: 110)
        .onDisappear(perform: stop)
    }

    private func start() {
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                stop()
                return nil
            }
            guard !modifiers.subtracting(.shift).isEmpty else {
                NSSound.beep()
                return nil
            }
            onChange(Shortcut(keyCode: Int(event.keyCode), modifiers: modifiers, keyLabel: Shortcut.label(for: event)))
            stop()
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        onRecordingChange(false)
    }
}
