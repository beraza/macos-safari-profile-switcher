#if SELF_TEST
import AppKit
import SwiftUI
import Carbon.HIToolbox
import SwitcherCore

/// `SafariProfileSwitcher --self-test`: exercises the AppleScript library against the running Safari on
/// temporary windows it creates and closes itself, then exits. Accessibility checks run only if trusted.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() -> Never {
        print("Accessibility trusted: \(AXIsProcessTrusted())")
        runLocalizationCheck()
        if let directory = ProcessInfo.processInfo.environment["SPSW_SNAPSHOT_DIR"] {
            snapshotSettings(to: URL(fileURLWithPath: directory))
        }
        if CommandLine.arguments.contains("--only-l10n") {
            print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        runSettingsChecks()
        runHotKeyChecks()
        do {
            try runChecks()
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures += 1 }
        print("\(condition ? "✓" : "✗") \(message())")
    }

    private static func pause(_ seconds: Double = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// п. 9: strings come from the catalogs (only inside the .app, where the .lproj folders are).
    private static func runLocalizationCheck() {
        let language = Bundle.main.preferredLocalizations.first ?? "?"
        let samples = [String(localized: "Settings…"), String(localized: "\(1) windows"),
                       String(localized: "\(3) windows"), String(localized: "\(5) windows"),
                       String(localized: "Always open \("example.com") in “\("Работа")”")]
        print("Localization \(language): \(samples)")
        if language == "ru" {
            check(samples == ["Настройки…", "1 окно", "3 окна", "5 окон", "Всегда открывать example.com в профиле «Работа»"],
                  "l10n: Russian with plurals")
        } else if Bundle.main.bundlePath.hasSuffix(".app") {
            check(samples == ["Settings…", "1 window", "3 windows", "5 windows", "Always open example.com in “Работа”"],
                  "l10n: English with plurals")
        }
    }

    /// Renders each settings tab to settings-N.png, with a sample rule.
    private static func snapshotSettings(to directory: URL) {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.switchProfiles = ["Личное", "Работа"]
        settings.linkRules = [
            LinkRule(pattern: "github.com/work-org", sourceApp: "com.tinyspeck.slackmacgap", profile: "Работа"),
            LinkRule(pattern: "*.ktalk.ru", profile: "", targetApp: "kontur.talk", targetScheme: "ktalk"),
        ]
        let controller = AppController(customSettings: settings, promptForAccessibility: false)
        for pane in SettingsPane.allCases {
            let tab = pane.rawValue
            let window = NSWindow(contentViewController: pane.viewController(controller: controller, settings: settings))
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFront(nil)
            pause(0.5)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-\(tab).png"))
            }
            window.orderOut(nil)
        }
        print("settings snapshots in \(directory.path)")
    }

    private static func runSettingsChecks() {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Legacy single shortcut ⌃` migrates to the switch action; everything else gets defaults.
        let legacy = Shortcut(keyCode: kVK_ANSI_Grave, modifiers: .control, keyLabel: "`")
        defaults.set(try? JSONEncoder().encode(legacy), forKey: "shortcut")
        var settings = AppSettings(defaults: defaults)
        check(settings.shortcuts[.switchProfile] == legacy, "settings: legacy shortcut migrated")
        check(settings.shortcuts[.detachTab] == ShortcutAction.detachTab.defaultShortcut, "settings: defaults for new actions")

        // Swap on conflict, disable, persist and reload.
        let changed = settings.setShortcut(ShortcutAction.attachTab.defaultShortcut, for: .detachTab)
        check(changed == .attachTab && settings.shortcuts[.attachTab] == ShortcutAction.detachTab.defaultShortcut,
              "settings: conflicting shortcut swapped")
        settings.setShortcut(nil, for: .hudCancel)
        settings.closeEmptyWindow = false
        settings = AppSettings(defaults: defaults)
        check(settings.shortcuts[.detachTab] == ShortcutAction.attachTab.defaultShortcut
              && settings.shortcuts[.attachTab] == ShortcutAction.detachTab.defaultShortcut
              && settings.shortcuts[.hudCancel] == nil
              && settings.shortcuts[.switchProfile] == legacy
              && !settings.closeEmptyWindow,
              "settings: survive reload")
        check(defaults.data(forKey: "shortcut") == nil, "settings: legacy key removed")

        let bindings = ShortcutAction.defaultBindings
        check(ShortcutAction.allCases.allSatisfy { action in
            bindings[action].map { ShortcutConflicts.conflict(for: action, key: $0, in: bindings) == nil } ?? true
        } && ShortcutAction.switchBack(for: bindings[.switchProfile]).map { back in
            !bindings.contains { $0.key.scopes.contains(.hud) && $0.value == back }
        } == true, "settings: default shortcuts don't clash (⌥⇧⇥ is free for going back)")
    }

    private static func runHotKeyChecks() {
        let manager = HotKeyManager()
        // Unusual combos nobody else should hold.
        let bindings: [ShortcutAction: Shortcut] = [
            .detachTab: Shortcut(keyCode: kVK_F17, modifiers: [.control, .option, .shift, .command], keyLabel: "F17"),
            .attachTab: Shortcut(keyCode: kVK_F18, modifiers: [.control, .option, .shift, .command], keyLabel: "F18"),
        ]
        manager.apply(bindings)
        check(manager.failures.isEmpty, "hotkeys: registered \(bindings.count)")
        // A second registration of the same keys in this process must fail and be reported.
        let other = HotKeyManager()
        other.apply([.switchProfile: bindings[.detachTab]!])
        check(other.failures[.switchProfile]?.status == OSStatus(eventHotKeyExistsErr), "hotkeys: taken keys reported")
        manager.apply([:])
        other.apply([.switchProfile: bindings[.detachTab]!])
        check(other.failures.isEmpty, "hotkeys: keys free again after unregistering")
        other.apply([:])
    }

    /// Builds the menu bar menu against the live Safari windows.
    private static func runMenuCheck(userWindows: [SafariWindow]) {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let profiles = Set(userWindows.compactMap { $0.title.components(separatedBy: ProfileMatcher.separator).first })
        settings.switchProfiles = [profiles.sorted().first ?? "Личное", "SelfTest Profile"]
        let controller = AppController(customSettings: settings, promptForAccessibility: false)
        let menu = StatusMenu(controller: controller) {}
        let lines = menu.renderedLines()
        print(lines.map { "    | \($0)" }.joined(separator: "\n"))
        check(lines.contains("[\(settings.switchProfiles[0])]") && lines.contains("[SelfTest Profile]"),
              "menu: sections for both profiles")
        let listed = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("✓ ") }.count
        check(listed >= userWindows.count, "menu: \(userWindows.count) windows listed")
        check(lines.first { $0.hasPrefix("✓ ") } != nil, "menu: front window checked")
    }

    /// п. 4: a tab moves back into the window it was detached from; the emptied window closes.
    private static func runAttachCheck(base: String, userWindows: [SafariWindow]) throws {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppController(customSettings: AppSettings(defaults: defaults), promptForAccessibility: false)

        let home = Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: base + "-home")).int32Value)
        defer { try? SafariController.close(windowID: home) }
        let detached = Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: base + "-solo")).int32Value)
        defer { try? SafariController.close(windowID: detached) }
        pause(1)
        controller.settings.detachedFrom[detached] = home
        var finished = false
        Task {
            do { try await controller.attachTab() } catch { check(false, "attachTab: \(error.localizedDescription)") }
            finished = true
        }
        while !finished { pause(0.05) }
        pause(0.5)
        let windows = try SafariController.windows()
        check(!windows.contains { $0.id == detached }, "attachTab: emptied window closed")
        check(windows.first?.id == home && windows.first?.tabCount == 2, "attachTab: tab is back in its window, which is in front")
        check(controller.settings.detachedFrom.isEmpty, "attachTab: bookkeeping cleared")
        try SafariController.close(windowID: home)
        pause()
        check(try SafariController.windows().map(\.id) == userWindows.map(\.id), "attachTab: user windows untouched")
    }

    /// п. 3: a link from another app goes, by rule and without tracking parameters, to its profile's window.
    /// A test window whose page title is "SPSW Rules" stands in for a profile ("Личное — SPSW Rules").
    private static func runLinkCheck(userWindows: [SafariWindow]) throws {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let page = "data:text/html,<title>SPSW Rules</title>"
        let window = Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: page)).int32Value)
        defer { try? SafariController.close(windowID: window) }
        pause(1)
        let title = try SafariController.windows().first { $0.id == window }?.title ?? ""
        let profile = title.hasSuffix("SPSW Rules") ? title : "SPSW Rules"
        settings.switchProfiles = [profile, "SelfTest Profile"]
        settings.linkRules = [LinkRule(pattern: "example.com", sourceApp: "com.apple.mail", profile: profile)]
        let controller = AppController(customSettings: settings, promptForAccessibility: false)

        check(controller.linkTarget(for: URL(string: "https://www.example.com/x")!, sourceApp: "com.apple.mail") == .profile(profile),
              "links: rule matches (\(profile))")
        check(controller.linkTarget(for: URL(string: "https://www.example.com/x")!, sourceApp: "com.apple.Notes") == .profile(AppSettings.safariDecides),
              "links: rule for another app doesn't, Safari decides")
        controller.openLink(URL(string: "https://example.com/?spsw-link&utm_source=selftest")!, sourceApp: "com.apple.mail")
        pause(1.5)
        let tab = try SafariController.currentTab()
        check(tab.windowID == window && tab.tabCount == 2 && tab.url == "https://example.com/?spsw-link",
              "links: opened in the rule's window without tracking: \(tab.url)")
        check(controller.lastError == nil, "links: no error \(controller.lastError ?? "")")

        settings.remember(host: "www.example.org", profile: profile)
        settings.remember(host: "example.org", profile: "SelfTest Profile")
        check(settings.linkRules.filter { $0.pattern == "example.org" }.map(\.profile) == ["SelfTest Profile"],
              "links: remembering a host adds or updates one rule")

        try SafariController.close(windowID: window)
        pause()
        check(try SafariController.windows().map(\.id) == userWindows.map(\.id), "links: user windows untouched")
    }

    /// п. 1: HUD rendering (PNG into $SPSW_SNAPSHOT_DIR) and activating its choice on test windows,
    /// whose page titles "SPSW One"/"SPSW Two" stand in for two profiles.
    private static func runHUDCheck(userWindows: [SafariWindow]) throws {
        let suite = "com.djonny.SafariProfileSwitcher.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func make(_ title: String) throws -> Int {
            Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: "data:text/html,<title>\(title)</title>")).int32Value)
        }
        let one = try make("SPSW One")
        defer { try? SafariController.close(windowID: one) }
        let two = try make("SPSW Two")
        defer { try? SafariController.close(windowID: two) }
        pause(1)
        var windows = try SafariController.windows()
        let titles = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.title) })
        guard let profileOne = titles[one], let profileTwo = titles[two] else {
            check(false, "hud: test windows listed")
            return
        }
        settings.switchProfiles = [profileOne, profileTwo]
        settings.profileBadges = [profileOne: "1", profileTwo: "2"]
        let controller = AppController(customSettings: settings, promptForAccessibility: false)

        let profilesState = HUDState.profiles(windows: windows, profiles: controller.knownProfiles)
        check(profilesState.groups.first?.profile == profileTwo && profilesState.selected?.target == .window(id: one),
              "hud: current profile first, the other's window selected")
        let directory = ProcessInfo.processInfo.environment["SPSW_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        controller.hud.model.look = { $0.map(controller.look(for:)) ?? .unknown }
        for (name, state) in [("profiles", profilesState),
                              ("windows", HUDState.windows(windows: windows, profiles: controller.knownProfiles,
                                                           tabs: (try? SafariController.tabs()) ?? [:]))] {
            controller.hud.show(state, near: nil)
            pause(0.3)
            let file = directory.appendingPathComponent("hud-\(name).png")
            try controller.hud.snapshot(to: file)
            check(FileManager.default.fileExists(atPath: file.path), "hud: rendered \(file.path)")
            controller.hud.hide()
        }

        var finished = false
        let opened = windows
        Task {
            do {
                try await controller.activate(profilesState.selected!, windows: opened)
            } catch {
                check(false, "hud: activate failed: \(error.localizedDescription)")
            }
            finished = true
        }
        while !finished { pause(0.05) }
        pause(0.5)
        windows = try SafariController.windows()
        check(windows.first?.id == one, "hud: activating a profile brings its window to the front")

        let windowItem = HUDItem(target: .window(id: two), title: "", profile: nil, count: 1)
        let current = windows
        finished = false
        Task {
            try? await controller.activate(windowItem, windows: current)
            finished = true
        }
        while !finished { pause(0.05) }
        pause(0.5)
        check(try SafariController.windows().first?.id == two, "hud: activating a window brings it to the front")

        try SafariController.close(windowID: one)
        try SafariController.close(windowID: two)
        pause()
        check(try SafariController.windows().map(\.id) == userWindows.map(\.id), "hud: user windows untouched")
    }

    private static func runChecks() throws {
        guard SafariController.runningApp != nil else {
            check(false, "Safari is running")
            return
        }
        let userWindows = try SafariController.windows()
        check(true, "listWindows: \(userWindows.count) windows")

        // п. 10: cached library vs. compiling the script on every call.
        let runs = 10
        let uncached = ContinuousClock().measure {
            for _ in 0..<runs { _ = try? SafariController.runUncompiled(SafariController.librarySource + "\nlistWindows()") }
        }
        let cached = ContinuousClock().measure {
            for _ in 0..<runs { _ = try? SafariController.windows() }
        }
        check(cached < uncached, "cached \(cached / runs) per call vs uncompiled \(uncached / runs)")

        let base = "https://example.com/?spsw-selftest"
        let a = Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: base + "-a")).int32Value)
        defer { try? SafariController.close(windowID: a) }
        try SafariController.openTab(url: base + "-b", windowID: a)
        pause()
        let tab = try SafariController.currentTab()
        check(tab.windowID == a && tab.index == 2 && tab.tabCount == 2 && tab.url.hasSuffix("-b"),
              "openTab + currentTabInfo: \(tab)")
        let tabsOfA = try SafariController.tabs()[a]
        check(tabsOfA?.titles.count == 2 && tabsOfA?.current == 1, "listTabs: \(String(describing: tabsOfA))")
        try SafariController.selectTab(index: 1, windowID: a)
        check(try SafariController.tabs()[a]?.current == 0, "selectTab: first tab is current")

        let b = Int(try SafariController.call("makeDocument", NSAppleEventDescriptor(string: base + "-c")).int32Value)
        defer { try? SafariController.close(windowID: b) }
        pause()
        try SafariController.moveTab(index: 2, from: a, to: b)
        pause()
        var windows = try SafariController.windows()
        let tabsA = windows.first { $0.id == a }?.tabCount
        let tabsB = windows.first { $0.id == b }?.tabCount
        check(tabsA == 1 && tabsB == 2, "moveTab: A has \(tabsA ?? -1) tabs, B has \(tabsB ?? -1)")

        let frame = CGRect(x: 120, y: 140, width: 900, height: 640)
        try SafariController.setBounds(frame, windowID: b)
        pause()
        let bounds = try SafariController.bounds(windowID: b)
        check(bounds == frame, "setBounds/bounds: \(bounds.map { "\($0)" } ?? "nil")")

        try SafariController.focus(windowID: a)
        pause()
        windows = try SafariController.windows()
        check(windows.first?.id == a, "focus: front window is A")

        try SafariController.setCurrentTabURL(base + "-d", windowID: a)
        pause(1)
        let url = try SafariController.currentTab().url
        check(url.hasSuffix("-d"), "setCurrentTabURL: \(url)")

        try SafariController.closeTab(index: 1, windowID: b)
        pause()
        windows = try SafariController.windows()
        check(windows.first { $0.id == b }?.tabCount == 1, "closeTab: B has 1 tab")

        let known = Set(windows.map(\.id))
        var newID: Int?
        Task { newID = try? await SafariController.waitForNewWindow(excluding: known) }
        pause(0.2)
        check(newID == nil, "waitForNewWindow keeps waiting while there is no new window")
        let made = try SafariController.call("makeDocument", NSAppleEventDescriptor(string: base + "-e")).int32Value
        let deadline = Date().addingTimeInterval(4)
        while newID == nil && Date() < deadline { pause(0.05) }
        check(newID == Int(made), "waitForNewWindow: \(newID.map(String.init) ?? "nil")")
        if let newID { try? SafariController.close(windowID: newID) }

        _ = try SafariController.runUncompiled("tell application \"Safari\" to set miniaturized of window id \(b) to true")
        pause(0.8)
        check(try SafariController.windows().contains { $0.id == b }, "minimized windows are listed")
        try SafariController.focus(windowID: b)
        pause(0.8)
        check(try SafariController.windows().first?.id == b, "focus restores a minimized window")

        try SafariController.close(windowID: a)
        try SafariController.close(windowID: b)
        pause()
        windows = try SafariController.windows()
        check(!windows.contains { $0.id == a || $0.id == b }, "closeWindow")
        check(windows.map(\.id) == userWindows.map(\.id), "user windows untouched, order restored")

        runMenuCheck(userWindows: userWindows)
        try runAttachCheck(base: base, userWindows: userWindows)
        try runLinkCheck(userWindows: userWindows)
        try runHUDCheck(userWindows: userWindows)

        if AXIsProcessTrusted() {
            print(SafariController.diagnostics())
        }
    }
}
#endif
