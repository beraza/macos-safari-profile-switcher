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
        case .moveTabToOtherProfile: String(localized: "Move tab to the other profile")
        case .detachTab: String(localized: "Move tab to a separate window")
        case .attachTab: String(localized: "Move tab back to the main window")
        case .hudNext: String(localized: "Switcher: next")
        case .hudPrevious: String(localized: "Switcher: previous")
        case .hudCancel: String(localized: "Switcher: cancel")
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .switchProfile: Shortcut(keyCode: kVK_Tab, modifiers: .option, keyLabel: "⇥")
        case .moveTabToOtherProfile: Shortcut(keyCode: kVK_Tab, modifiers: [.option, .shift], keyLabel: "⇥")
        case .detachTab: Shortcut(keyCode: kVK_UpArrow, modifiers: [.option, .shift], keyLabel: "↑")
        case .attachTab: Shortcut(keyCode: kVK_DownArrow, modifiers: [.option, .shift], keyLabel: "↓")
        case .hudNext: Shortcut(keyCode: kVK_RightArrow, modifiers: .option, keyLabel: "→")
        case .hudPrevious: Shortcut(keyCode: kVK_Tab, modifiers: [.option, .shift], keyLabel: "⇥")
        case .hudCancel: Shortcut(keyCode: kVK_Escape, modifiers: .option, keyLabel: "⎋")
        }
    }

    static var defaultBindings: [ShortcutAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } })
    }
}

/// What the switch shortcut does when Safari isn't the front app.
enum OutsideSafariAction: String, CaseIterable, Identifiable {
    case activateSafari, switchProfile, passThrough

    var id: Self { self }

    var title: String {
        switch self {
        case .activateSafari: String(localized: "Activate Safari")
        case .switchProfile: String(localized: "Activate Safari and switch profile")
        case .passThrough: String(localized: "Nothing (leave the shortcut to other apps)")
        }
    }
}

/// What the switcher HUD lists.
enum HUDMode: String, CaseIterable, Identifiable {
    case off, profiles, windows

    var id: Self { self }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .profiles: String(localized: "Profiles")
        case .windows: String(localized: "Windows")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
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
    @Published var showProfileIndicator: Bool {
        didSet { defaults.set(showProfileIndicator, forKey: "showProfileIndicator") }
    }
    /// Link rules, first match wins.
    @Published var linkRules: [LinkRule] {
        didSet { defaults.set(try? JSONEncoder().encode(linkRules), forKey: "linkRules") }
    }
    /// Profile for links no rule matches; empty means "ask".
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
            ?? .activateSafari
        newWindowInPlace = defaults.object(forKey: "newWindowInPlace") as? Bool ?? true
        matchFullScreen = defaults.object(forKey: "matchFullScreen") as? Bool ?? true
        alignExistingWindows = defaults.object(forKey: "alignExistingWindows") as? Bool ?? false
        keepSourceTab = defaults.object(forKey: "keepSourceTab") as? Bool ?? false
        hudMode = defaults.string(forKey: "hudMode").flatMap(HUDMode.init) ?? .profiles
        hudDelay = defaults.object(forKey: "hudDelay") as? Double ?? 0.2
        showProfileIndicator = defaults.object(forKey: "showProfileIndicator") as? Bool ?? true
        profileBadges = defaults.dictionary(forKey: "profileBadges") as? [String: String] ?? [:]
        linkRules = defaults.data(forKey: "linkRules").flatMap { try? JSONDecoder().decode([LinkRule].self, from: $0) } ?? []
        defaultLinkProfile = defaults.string(forKey: "defaultLinkProfile") ?? ""
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
        ProfileMatcher.cleaned(switchProfiles + linkRules.map(\.profile) + [defaultLinkProfile])
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

    func badge(for profile: String) -> String {
        let custom = profileBadges[profile]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? String(profile.prefix(1)).uppercased() : custom
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
    private struct StoredShortcuts: Codable {
        var custom: [String: Shortcut] = [:]
        var disabled: [String] = []
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [ShortcutAction: Shortcut] {
        var bindings = ShortcutAction.defaultBindings
        if let data = defaults.data(forKey: "shortcuts"),
           let stored = try? JSONDecoder().decode(StoredShortcuts.self, from: data) {
            for (name, shortcut) in stored.custom {
                if let action = ShortcutAction(rawValue: name) { bindings[action] = shortcut }
            }
            for name in stored.disabled {
                if let action = ShortcutAction(rawValue: name) { bindings[action] = nil }
            }
        } else if let data = defaults.data(forKey: "shortcut"),
                  let legacy = try? JSONDecoder().decode(Shortcut.self, from: data) {
            // Before per-action shortcuts there was only the switch shortcut.
            ShortcutConflicts.assign(legacy, to: .switchProfile, in: &bindings)
        }
        return bindings
    }

    private func saveShortcuts() {
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
        defaults.set(try? JSONEncoder().encode(stored), forKey: "shortcuts")
        defaults.removeObject(forKey: "shortcut")
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
