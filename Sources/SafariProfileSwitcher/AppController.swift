import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwitcherCore

@MainActor
final class AppController: ObservableObject {
    let settings: AppSettings
    @Published private(set) var detectedProfiles: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var automationStatus = ""
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Shortcuts that couldn't be registered, with the reason.
    @Published private(set) var hotKeyFailures: [ShortcutAction: String] = [:]
    /// Profile of Safari's focused window (the last one seen while Safari was in front).
    @Published private(set) var currentProfile: String?

    private let hotKey = HotKeyManager()
    let hud = SwitcherHUD()
    /// Polls the modifiers from the first press of the switch shortcut until they are released.
    private var hudTimer: Timer?
    private var hudPressedAt: ContinuousClock.Instant?
    /// Presses of the switch shortcut before the HUD appeared.
    private var hudExtraPresses = 0
    private var hudState: HUDState?
    /// Safari windows when the HUD opened, front-most first.
    private var hudWindows: [SafariWindow] = []
    private let observer = SafariObserver()
    private var safariActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SafariController.bundleID
    private var hotKeyPaused = false
    /// Windows already shown in the current round of cycling through a profile.
    private var cycle: CycleState?
    /// Set while an action waits for Safari (e.g. for a new window), so presses don't interleave.
    private var isBusy = false
    /// Window a detached tab came from, by the id of the window it was moved into (internal for the self-test).
    var detachedFrom: [Int: Int] = [:]
    /// The last tab moved to another profile, offered as a link rule in the menu.
    @Published private(set) var lastTransfer: (host: String, profile: String)?
    private var cancellables: Set<AnyCancellable> = []

    init(customSettings: AppSettings? = nil, promptForAccessibility: Bool = true) {
        settings = customSettings ?? AppSettings()
        hotKey.onPress = { [weak self] action in
            MainActor.assumeIsolated { self?.handle(action) }
        }
        observer.onChange = { [weak self] in self?.updateCurrentProfile() }

        // @Published fires before the value is stored, so react on the next run loop pass.
        Publishers.Merge(settings.$shortcuts.map { _ in () }, settings.$outsideSafariAction.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateHotKeyRegistration() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.frontAppChanged(isSafari: app?.bundleIdentifier == SafariController.bundleID)
            }
            .store(in: &cancellables)
        Publishers.Merge(
            workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .filter { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            == SafariController.bundleID }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.observer.start()
            self?.updateCurrentProfile()
        }
        .store(in: &cancellables)

        updateHotKeyRegistration()
        if promptForAccessibility && !accessibilityGranted {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        refreshProfiles()
        refreshPermissions()
        observer.start()
        updateCurrentProfile()
    }

    var profilesSummary: String {
        let first = settings.firstProfile.isEmpty ? "?" : settings.firstProfile
        let second = settings.secondProfile.isEmpty ? "?" : settings.secondProfile
        return "\(first) ⇄ \(second)"
    }

    /// Configured and detected profile names, without duplicates.
    var knownProfiles: [String] {
        var seen = Set<String>()
        return (settings.profilePair + detectedProfiles).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Hotkeys

    /// Paused while the settings window records a new shortcut, so the old ones don't fire.
    func setHotKeyPaused(_ paused: Bool) {
        hotKeyPaused = paused
        updateHotKeyRegistration()
    }

    private func frontAppChanged(isSafari: Bool) {
        safariActive = isSafari
        if !isSafari && (hud.isVisible || hudTimer != nil) {
            closeHUD(confirm: false)
        }
        updateHotKeyRegistration()
        if isSafari {
            observer.start()
            updateCurrentProfile()
        }
    }

    /// Registers the shortcuts of the current scope: Safari's while it's in front; outside Safari only
    /// the switch shortcut, and not even that with "pass through", so other apps get the keys.
    private func updateHotKeyRegistration() {
        var bindings: [ShortcutAction: Shortcut] = [:]
        if hotKeyPaused {
            bindings = [:]
        } else if hud.isVisible {
            bindings = settings.shortcuts.filter { $0.key.scopes.contains(.hud) }
        } else if safariActive {
            bindings = settings.shortcuts.filter { $0.key.scopes.contains(.safari) }
        } else if settings.outsideSafariAction != .passThrough {
            bindings[.switchProfile] = settings.shortcuts[.switchProfile]
        }
        hotKey.apply(bindings)
        // Show only failures of the shortcuts as they are set now.
        hotKeyFailures = hotKey.failures.reduce(into: [:]) { result, failure in
            guard settings.shortcuts[failure.key] == failure.value.shortcut else { return }
            result[failure.key] = failure.value.status == OSStatus(eventHotKeyExistsErr)
                ? String(localized: "Taken by another app or the system")
                : String(localized: "Can't register (error \(String(failure.value.status)))")
        }
    }

    private func handle(_ action: ShortcutAction) {
        switch action {
        case .switchProfile:
            handleSwitchShortcut()
        case .moveTabToOtherProfile:
            perform { try await $0.moveTabToOtherProfile() }
        case .detachTab:
            perform { try await $0.detachTab() }
        case .attachTab:
            perform { try await $0.attachTab() }
        case .hudNext:
            moveHUD(by: 1)
        case .hudPrevious:
            moveHUD(by: -1)
        case .hudCancel:
            closeHUD(confirm: false)
        }
    }

    /// Runs one Safari action at a time; a press while another is still waiting on Safari is dropped.
    private func perform(_ action: @escaping (AppController) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await action(self)
                lastError = nil
            } catch {
                cycle = nil
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Switching

    private func handleSwitchShortcut() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SafariController.bundleID {
            if hud.isVisible || hudTimer != nil || (settings.hudMode != .off && !hudHoldFlags.isEmpty) {
                switchShortcutPressedWithHUD()
            } else {
                perform { try await $0.switchProfile() }
            }
            return
        }
        switch settings.outsideSafariAction {
        case .switchProfile where SafariController.runningApp != nil:
            SafariController.runningApp?.activate()
            perform { try await $0.switchProfile() }
        case .activateSafari, .switchProfile, .passThrough:
            openSafari()
        }
    }

    /// Launches or activates Safari; "opening" a running app also makes it reopen a window if it has none.
    private func openSafari() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            fail(String(localized: "Safari not found"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.fail(error.localizedDescription) }
        }
    }

    func switchProfile() async throws {
        if settings.firstProfile.isEmpty || settings.secondProfile.isEmpty {
            refreshProfiles()
        }
        let windows = try SafariController.windows()
        guard let plan = Switcher.decide(
            windows: windows, first: settings.firstProfile, second: settings.secondProfile, cycle: cycle,
            closeEmpty: settings.closeEmptyWindow)
        else {
            throw AppError(String(localized: "Choose two different profiles in Settings"))
        }
        cycle = plan.cycle
        let front = windows.first
        switch plan.target {
        case .focus(let windowID):
            if settings.alignExistingWindows, let front, let target = windows.first(where: { $0.id == windowID }),
               profile(ofTitle: front.title) != profile(ofTitle: target.title) {
                try align(windowID, with: front.id)
            }
            try SafariController.focus(windowID: windowID)
        case .openNew(let profile):
            _ = try await openNewWindow(profile: profile, replacing: front?.id)
        }
        if let closeID = plan.closeWindowID {
            try SafariController.close(windowID: closeID)
        }
    }

    /// Opens a new window of `profile` and, with "in place", gives it the frame (or full screen) of `source`.
    /// - Returns: the new window's id.
    private func openNewWindow(profile: String, replacing source: Int?) async throws -> Int {
        let known = Set(try SafariController.windows().map(\.id))
        var frame: CGRect?
        var fullScreen = false
        if settings.newWindowInPlace, let source {
            fullScreen = SafariController.isFullScreen(windowID: source)
            frame = try SafariController.bounds(windowID: source)
        }
        try SafariController.openNewWindow(profile: profile)
        let newID = try await SafariController.waitForNewWindow(excluding: known)
        if fullScreen {
            // A full-screen frame makes no sense for a window on the desktop, so either match or leave it.
            if settings.matchFullScreen { SafariController.setFullScreen(windowID: newID) }
        } else if let frame {
            try SafariController.setBounds(frame, windowID: newID)
        }
        return newID
    }

    /// Moves `windowID` onto `reference`'s frame, unless either is full screen.
    private func align(_ windowID: Int, with reference: Int) throws {
        guard !SafariController.isFullScreen(windowID: reference), !SafariController.isFullScreen(windowID: windowID),
              let frame = try SafariController.bounds(windowID: reference)
        else { return }
        try SafariController.setBounds(frame, windowID: windowID)
    }

    private func profile(ofTitle title: String) -> String? {
        ProfileMatcher.profile(ofTitle: title, among: knownProfiles)
    }

    // MARK: - Tabs

    /// Opens the current tab's URL in the other profile (or the one a link rule picks) and closes the tab.
    func moveTabToOtherProfile() async throws {
        let tab = try SafariController.currentTab()
        let windows = try SafariController.windows()
        let result = TabTransfer.plan(
            tab: tab, windows: windows, first: settings.firstProfile, second: settings.secondProfile,
            preferredProfile: preferredProfile(for: tab.url), keepSource: settings.keepSourceTab)
        let plan: TabTransferPlan
        switch result {
        case .success(let value): plan = value
        case .failure(.profilesNotConfigured):
            throw AppError(String(localized: "Choose two different profiles in Settings"))
        case .failure(.nothingToMove):
            throw AppError(String(localized: "Nothing to move: the tab shows the start page"))
        }
        // Open first, close after: a failure must never lose the tab.
        switch plan.target {
        case .window(let id):
            try SafariController.openTab(url: tab.url, windowID: id)
            try SafariController.focus(windowID: id)
        case .newWindow(let profile):
            let id = try await openNewWindow(profile: profile, replacing: tab.windowID)
            try SafariController.setCurrentTabURL(tab.url, windowID: id)
        }
        switch plan.cleanup {
        case .none: break
        case .closeTab(let windowID, let index): try SafariController.closeTab(index: index, windowID: windowID)
        case .closeWindow(let id): try SafariController.close(windowID: id)
        }
        cycle = nil
        if let host = URL(string: tab.url)?.host() {
            lastTransfer = (host, plan.profile)
        }
    }

    /// Moves the current tab into a new window of its profile, keeping its history.
    func detachTab() async throws {
        let tab = try SafariController.currentTab()
        guard tab.tabCount > 1 else {
            throw AppError(String(localized: "The tab is already alone in its window"))
        }
        let known = Set(try SafariController.windows().map(\.id))
        let newID: Int
        if try SafariController.moveCurrentTabToNewWindow() {
            newID = try await SafariController.waitForNewWindow(excluding: known)
        } else {
            // No "Move Tab to New Window" item: open a window of the profile and move the tab there.
            guard let profile = profile(ofTitle: tab.windowTitle) else {
                throw AppError(String(localized: "Can't tell the profile of this window"))
            }
            newID = try await openNewWindow(profile: profile, replacing: nil)
            try SafariController.moveTab(index: tab.index, from: tab.windowID, to: newID)
            try SafariController.closeTab(index: 1, windowID: newID)
        }
        detachedFrom[newID] = tab.windowID
    }

    /// Moves the current tab back into the window it was detached from (or another window of its profile).
    /// A window left without tabs closes by itself.
    func attachTab() async throws {
        let tab = try SafariController.currentTab()
        let windows = try SafariController.windows()
        guard let target = TabAttach.target(
            windows: windows, sourceWindowID: tab.windowID, profiles: knownProfiles,
            detachedFrom: detachedFrom[tab.windowID])
        else {
            throw AppError(String(localized: "No other window of this profile"))
        }
        try SafariController.moveTab(index: tab.index, from: tab.windowID, to: target)
        try SafariController.focus(windowID: target)
        if tab.tabCount <= 1 {
            detachedFrom[tab.windowID] = nil
        }
        let open = Set(windows.map(\.id))
        detachedFrom = detachedFrom.filter { open.contains($0.key) && open.contains($0.value) }
    }

    // MARK: - Menu actions

    /// Brings a window to the front and activates Safari (from the menu bar list).
    func showWindow(id: Int) {
        perform { _ in
            try SafariController.focus(windowID: id)
            SafariController.runningApp?.activate()
        }
    }

    func openWindow(profile: String) {
        perform {
            SafariController.runningApp?.activate()
            _ = try await $0.openNewWindow(profile: profile, replacing: nil)
        }
    }

    /// Turns the last moved tab into a link rule (host → profile).
    func rememberLastTransfer() {
        guard let transfer = lastTransfer else { return }
        settings.remember(host: transfer.host, profile: transfer.profile)
        lastTransfer = nil
    }

    /// Profile a link rule assigns to `url` (rules with a source app don't apply to tabs).
    private func preferredProfile(for url: String) -> String? {
        URL(string: url).flatMap { RuleMatcher.profile(for: $0, sourceApp: nil, rules: settings.linkRules) }
    }

    // MARK: - Links (default browser)

    /// Profile for a link opened from another app: rule, default profile, or `nil` to ask.
    func linkProfile(for url: URL, sourceApp: String?) -> String? {
        RuleMatcher.profile(for: url, sourceApp: sourceApp, rules: settings.linkRules)
            ?? (settings.defaultLinkProfile.isEmpty ? nil : settings.defaultLinkProfile)
    }

    /// Opens a link from another app in the profile its rules pick; asks when none does or ⌥ is held.
    func openLink(_ url: URL, sourceApp: String?, forceChoice: Bool = false) {
        let url = url.isFileURL ? url : LinkCleaner.clean(url, stripTracking: settings.stripTrackingParams)
        log.info("link \(url.absoluteString, privacy: .private) from \(sourceApp ?? "?", privacy: .public)")
        if !forceChoice, let profile = linkProfile(for: url, sourceApp: sourceApp) {
            route(url, to: profile)
        } else {
            chooseProfile(for: url)
        }
    }

    private func route(_ url: URL, to profile: String) {
        Task {
            do {
                try await launchSafariIfNeeded()
                let windows = try SafariController.windows()
                if let window = windows.first(where: { self.profile(ofTitle: $0.title) == profile }) {
                    try SafariController.openTab(url: url.absoluteString, windowID: window.id)
                    try SafariController.focus(windowID: window.id)
                } else {
                    let id = try await openNewWindow(profile: profile, replacing: nil)
                    try SafariController.setCurrentTabURL(url.absoluteString, windowID: id)
                }
                SafariController.runningApp?.activate()
            } catch {
                // Never lose a link: let Safari open it the usual way.
                fail(String(localized: "Couldn't open the link in “\(profile)”: \(error.localizedDescription)"))
                openInSafari(url)
            }
        }
    }

    func openInSafari(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A menu at the mouse pointer with the profiles; hold ⌥ to also remember the choice for the host.
    private func chooseProfile(for url: URL) {
        let menu = NSMenu()
        let header = NSMenuItem(title: Self.shortened(url.absoluteString), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let host = url.host()
        for profile in knownProfiles {
            menu.addItem(ClosureMenuItem(title: profile) { [weak self] in self?.route(url, to: profile) })
            if let host {
                let remember = ClosureMenuItem(title: String(localized: "\(profile) — always for \(host)")) { [weak self] in
                    self?.settings.remember(host: host, profile: profile)
                    self?.route(url, to: profile)
                }
                remember.isAlternate = true
                remember.keyEquivalentModifierMask = .option
                menu.addItem(remember)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Open in Safari as usual")) { [weak self] in
            self?.openInSafari(url)
        })
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func shortened(_ text: String) -> String {
        text.count > 70 ? text.prefix(69) + "…" : text
    }

    /// Launches Safari in the background and waits until it answers AppleScript.
    private func launchSafariIfNeeded() async throws {
        guard SafariController.runningApp == nil else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            throw AppError(String(localized: "Safari not found"))
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

    /// Whether this app opens http(s) links.
    var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Makes this app (or Safari again) the default browser; macOS asks the user to confirm.
    func setDefaultBrowser(_ enabled: Bool) {
        let app = enabled ? Bundle.main.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID)
        guard let app else { return }
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
                }
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
            } catch {
                fail(error.localizedDescription)
            }
            objectWillChange.send()
        }
    }

    struct AppError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Switcher HUD

    /// Modifiers of the switch shortcut; the HUD stays open while they are held.
    private var hudHoldFlags: NSEvent.ModifierFlags { settings.shortcuts[.switchProfile]?.holdFlags ?? [] }

    /// Like ⌘⇥: a quick press and release switches right away; holding the modifier past the delay
    /// (or pressing again) shows the HUD, and releasing it activates the selection.
    private func switchShortcutPressedWithHUD() {
        if hud.isVisible {
            moveHUD(by: 1)
            return
        }
        if hudTimer != nil {
            hudExtraPresses += 1
            showHUD()
            return
        }
        hudPressedAt = .now
        hudExtraPresses = 0
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hudTick() }
        }
        if settings.hudDelay <= 0 { showHUD() }
    }

    private func hudTick() {
        guard Self.modifiersHeld(hudHoldFlags) else {
            if hud.isVisible {
                closeHUD(confirm: true)
            } else {
                stopHUDTimer()
                perform { try await $0.switchProfile() }
            }
            return
        }
        if !hud.isVisible, let pressedAt = hudPressedAt, ContinuousClock.now - pressedAt >= .seconds(settings.hudDelay) {
            showHUD()
        }
    }

    private func showHUD() {
        guard !hud.isVisible else { return }
        do {
            let windows = try SafariController.windows()
            var state = settings.hudMode == .windows
                ? HUDState.windows(windows: windows, profiles: knownProfiles)
                : HUDState.profiles(windows: windows, profiles: knownProfiles)
            state.move(by: hudExtraPresses)
            hudState = state
            hudWindows = windows
            hud.model.badge = { [settings] in settings.badge(for: $0) }
            hud.model.onClick = { [weak self] index in
                self?.hudState?.select(index)
                self?.closeHUD(confirm: true)
            }
            let frame = windows.first.flatMap { try? SafariController.bounds(windowID: $0.id) }
            hud.show(state, near: frame)
            updateHotKeyRegistration()
        } catch {
            stopHUDTimer()
            fail(error.localizedDescription)
        }
    }

    private func moveHUD(by offset: Int) {
        guard hud.isVisible, var state = hudState else { return }
        state.move(by: offset)
        hudState = state
        hud.update(state)
    }

    private func closeHUD(confirm: Bool) {
        stopHUDTimer()
        let selected = hudState?.selected
        let windows = hudWindows
        hud.hide()
        hudState = nil
        hudWindows = []
        updateHotKeyRegistration()
        guard confirm, let selected else { return }
        perform { try await $0.activate(selected, windows: windows) }
    }

    private func stopHUDTimer() {
        hudTimer?.invalidate()
        hudTimer = nil
        hudPressedAt = nil
    }

    /// Shows the HUD's choice: a window, or a profile's front-most window (a new one if it has none).
    func activate(_ item: HUDItem, windows: [SafariWindow]) async throws {
        let front = windows.first
        cycle = nil
        switch item.target {
        case .window(let id):
            guard id != front?.id else { return }
            try SafariController.focus(windowID: id)
        case .profile(let target):
            guard target != front.flatMap({ profile(ofTitle: $0.title) }) else { return }
            if let window = windows.first(where: { profile(ofTitle: $0.title) == target }) {
                if settings.alignExistingWindows, let front { try align(window.id, with: front.id) }
                try SafariController.focus(windowID: window.id)
            } else {
                _ = try await openNewWindow(profile: target, replacing: front?.id)
            }
        }
        if settings.closeEmptyWindow, let front, front.isEmptyStartPage, profile(ofTitle: front.title) != nil {
            try SafariController.close(windowID: front.id)
        }
    }

    /// Reads the hardware modifier state (no permission needed, works while another app is in front).
    private static func modifiersHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        let state = CGEventSource.flagsState(.combinedSessionState)
        var held: NSEvent.ModifierFlags = []
        if state.contains(.maskCommand) { held.insert(.command) }
        if state.contains(.maskAlternate) { held.insert(.option) }
        if state.contains(.maskControl) { held.insert(.control) }
        if state.contains(.maskShift) { held.insert(.shift) }
        return held.isSuperset(of: flags)
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        lastError = message
        NSSound.beep()
    }

    // MARK: - Profiles

    private func updateCurrentProfile() {
        guard SafariController.runningApp != nil else { return }
        let title = observer.focusedWindowTitle() ?? ""
        let profile = ProfileMatcher.profile(ofTitle: title, among: knownProfiles)
        if profile != currentProfile, !title.isEmpty {
            currentProfile = profile
        }
    }

    /// Detects profiles from Safari and fills in empty settings with the first two found.
    func refreshProfiles() {
        guard SafariController.runningApp != nil else { return }
        detectedProfiles = SafariController.detectProfiles()
        if settings.firstProfile.isEmpty, let first = detectedProfiles.first {
            settings.firstProfile = first
        }
        if settings.secondProfile.isEmpty,
           let second = detectedProfiles.first(where: { $0 != settings.firstProfile }) {
            settings.secondProfile = second
        }
    }

    func writeDiagnostics() {
        do {
            NSWorkspace.shared.open(try SafariController.writeDiagnostics())
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Permissions & login item

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        automationStatus = Self.describe(automationPermission(ask: false))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if accessibilityGranted && !observer.isRunning {
            observer.start()
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func requestAutomation() {
        Task.detached {
            let status = self.automationPermission(ask: true)
            await MainActor.run { self.automationStatus = Self.describe(status) }
            if status == OSStatus(errAEEventNotPermitted) {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
    }

    private nonisolated func automationPermission(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: SafariController.bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    private nonisolated static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case Int(noErr): String(localized: "✅ Allowed")
        case errAEEventNotPermitted: String(localized: "⚠️ Denied")
        case errAEEventWouldRequireUserConsent: String(localized: "Not asked yet")
        case procNotFound: String(localized: "Safari is not running")
        default: String(localized: "Code \(String(status))")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            fail(error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
