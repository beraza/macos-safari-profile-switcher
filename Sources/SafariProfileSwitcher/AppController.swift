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
    /// Numbered profile shortcuts that couldn't be registered ("⌃⌥1"), with the reason.
    @Published private(set) var numberedHotKeyFailures: [String] = []
    /// Profile of Safari's focused window (the last one seen while Safari was in front).
    @Published private(set) var currentProfile: String?

    /// Settings or Safari state that keep profiles from working as configured.
    @Published private(set) var profileWarnings: [ProfileWarning] = []

    /// Safari itself (a fake in tests).
    let safari: SafariAPI
    private let hotKey = HotKeyManager()
    /// Off in tests, so they don't take the user's keys.
    private let registersHotKeys: Bool
    private let hudController: HUDController
    private lazy var tabSearch = TabSearchPanel(controller: self)
    var hud: SwitcherHUD { hudController.hud }
    private let observer = SafariObserver()
    /// Safari is the front app.
    @Published var safariActive =
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SafariController.bundleID
    private var hotKeyPaused = false
    /// Windows already shown in the current round of cycling through a profile.
    var cycle: CycleState?
    /// The last queued Safari action; the next one waits for it.
    private var queue: Task<Void, Never>?
    /// Queued Safari actions, including the running one.
    private var queuedActions = 0
    /// The last tab moved to another profile, offered as a link rule in the menu.
    @Published private(set) var lastTransfer: (host: String, profile: String)?
    private var cancellables: Set<AnyCancellable> = []

    init(customSettings: AppSettings? = nil, promptForAccessibility: Bool = true, safari: SafariAPI? = nil,
         registersHotKeys: Bool = true) {
        settings = customSettings ?? AppSettings()
        self.safari = safari ?? LiveSafari()
        self.registersHotKeys = registersHotKeys
        hudController = HUDController(settings: settings, safari: self.safari)
        hudController.knownProfiles = { [weak self] in self?.knownProfiles ?? [] }
        hudController.isBusy = { [weak self] in (self?.queuedActions ?? 0) > 0 }
        hudController.onSwitchNow = { [weak self] outsideSafari in
            // Like a quick ⌘⇥: from another app, just go to Safari; in Safari, switch the profile.
            if outsideSafari { self?.showLastWindow() } else { self?.perform { try await $0.switchProfile() } }
        }
        hudController.onActivate = { [weak self] item, windows, tab in
            self?.perform { try await $0.activate(item, windows: windows, tab: tab) }
        }
        hudController.onAction = { [weak self] action in self?.perform { try await $0.run(action) } }
        hudController.onVisibilityChange = { [weak self] in self?.updateHotKeyRegistration() }
        hudController.onError = { [weak self] in self?.fail($0) }
        hotKey.onPress = { [weak self] command in
            MainActor.assumeIsolated { self?.handle(command) }
        }
        observer.onChange = { [weak self] in self?.updateCurrentProfile() }

        // @Published fires before the value is stored, so react on the next run loop pass.
        Publishers.Merge4(
            settings.$shortcuts.map { _ in () }, settings.$outsideSafariAction.map { _ in () },
            settings.$profileNumberModifier.map { _ in () }, settings.$moveTabNumberModifier.map { _ in () }
        )
            .merge(with: settings.$switchProfiles.map { _ in () })
            .dropFirst(5)
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
        .sink { [weak self] note in
            if note.name == NSWorkspace.didTerminateApplicationNotification {
                // Window ids start over when Safari launches again.
                self?.settings.detachedFrom = [:]
                self?.currentProfile = nil
            }
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

    /// Configured and detected profile names, without duplicates, and Private Browsing.
    var knownProfiles: [String] {
        ProfileMatcher.cleaned(settings.switchProfiles + detectedProfiles + [ProfileMatcher.privateProfile])
    }

    func look(for profile: String) -> ProfileLook {
        settings.look(for: profile, among: knownProfiles)
    }

    // MARK: - Hotkeys

    /// Paused while the settings window records a new shortcut, so the old ones don't fire.
    func setHotKeyPaused(_ paused: Bool) {
        hotKeyPaused = paused
        updateHotKeyRegistration()
    }

    func frontAppChanged(isSafari: Bool) {
        safariActive = isSafari
        if !isSafari && hudController.isActive {
            hudController.cancel()
        }
        updateHotKeyRegistration()
        if isSafari {
            observer.start()
            updateCurrentProfile()
        }
    }

    /// Registers the shortcuts of the current scope: the switcher's from the first press of the switch
    /// shortcut until it's done; Safari's while it's in front; outside Safari only the switch shortcut, and
    /// not even that with "pass through", so other apps get the keys.
    func updateHotKeyRegistration() {
        guard registersHotKeys else { return }
        let bindings = hotKeyBindings
        hotKey.apply(bindings)
        // Show only failures of the shortcuts as they are set now.
        func reason(_ status: OSStatus) -> String {
            status == OSStatus(eventHotKeyExistsErr) ? String(localized: "Taken by another app or the system")
                : String(localized: "Can't register (error \(String(status)))")
        }
        hotKeyFailures = hotKey.failures.reduce(into: [:]) { result, failure in
            guard case .action(let action) = failure.key, action.isConfigurable,
                  settings.shortcuts[action] == failure.value.shortcut else { return }
            result[action] = reason(failure.value.status)
        }
        // Kept from the last time Safari was in front, so the settings can show them.
        if safariActive {
            numberedHotKeyFailures = hotKey.failures
                .filter { if case .action = $0.key { false } else { bindings[$0.key] == $0.value.shortcut } }
                .map { "\($0.value.shortcut.displayString): \(reason($0.value.status))" }
                .sorted()
        }
    }

    /// The shortcuts of the current scope (see `updateHotKeyRegistration`).
    var hotKeyBindings: [HotKeyCommand: Shortcut] {
        var bindings: [HotKeyCommand: Shortcut] = [:]
        func add(_ actions: [ShortcutAction: Shortcut]) {
            for (action, shortcut) in actions { bindings[.action(action)] = shortcut }
        }
        if hotKeyPaused {
            return [:]
        } else if hudController.isActive {
            add(settings.shortcuts.filter { $0.key.scopes.contains(.hud) })
            // ⌥⇧⇥ goes back, unless the user gave those keys to a switcher action.
            if let back = ShortcutAction.switchBack(for: settings.shortcuts[.switchProfile]),
               !bindings.values.contains(back) {
                bindings[.action(.switchBack)] = back
            }
        } else if safariActive {
            add(settings.shortcuts.filter { $0.key.scopes.contains(.safari) })
            // ⌥1…⌥9 and ⌃⌥1…⌃⌥9 for the profiles in the list, unless those keys are taken by an action.
            for number in settings.switchProfiles.indices.prefix(9).map({ $0 + 1 }) {
                for (command, modifier) in [(HotKeyCommand.goToProfile(number), settings.profileNumberModifier),
                                            (.moveTabToProfile(number), settings.moveTabNumberModifier)] {
                    if let shortcut = modifier.shortcut(number), !bindings.values.contains(shortcut) {
                        bindings[command] = shortcut
                    }
                }
            }
        } else if settings.outsideSafariAction != .passThrough {
            add(settings.shortcuts.filter { $0.key == .switchProfile || $0.key == .searchTabs })
        }
        return bindings
    }

    private func handle(_ command: HotKeyCommand) {
        switch command {
        case .action(let action): handle(action)
        case .goToProfile(let number): perform { try await $0.goToProfile(number: number) }
        case .moveTabToProfile(let number): perform { try await $0.moveTabToProfile(number: number) }
        }
    }

    private func handle(_ action: ShortcutAction) {
        switch action {
        case .switchProfile:
            handleSwitchShortcut()
        case .moveTabToOtherProfile:
            perform { try await $0.moveTabToOtherProfile() }
        case .moveWindowToOtherProfile:
            perform { try await $0.moveWindowToOtherProfile() }
        case .searchTabs:
            tabSearch.show()
        case .detachTab:
            perform { try await $0.detachTab() }
        case .attachTab:
            perform { try await $0.attachTab() }
        case .hudNext:
            hudController.step(.next)
        case .hudPrevious:
            hudController.step(.previous)
        case .hudUp:
            hudController.step(.up)
        case .hudDown:
            hudController.step(.down)
        case .hudCloseTab:
            hudController.closeSelected(.tab)
        case .hudCloseWindow:
            hudController.closeSelected(.window)
        case .hudMoveTab:
            hudController.runOnSelection(.moveTab)
        case .hudMoveWindow:
            hudController.runOnSelection(.moveWindow)
        case .hudDetachTab:
            hudController.runOnSelection(.detachTab)
        case .switchBack:
            hudController.pressBack()
        case .hudCancel:
            hudController.cancel()
        }
    }

    /// Queues an action from a shortcut or the menu. One action may wait behind the running one (a quick
    /// double press switches twice); further presses are dropped with a beep, so they don't pile up while
    /// Safari is slow.
    func perform(_ action: @escaping (AppController) async throws -> Void) {
        guard queuedActions < 2 else {
            NSSound.beep()
            return
        }
        enqueue(action) { [weak self] error in self?.fail(error.localizedDescription) }
    }

    /// Runs Safari actions one after another, so one never interleaves with another that waits on Safari
    /// (e.g. two of them opening windows and each taking the other's new window for its own).
    /// Waits until the queued actions are done (tests).
    func waitUntilIdle() async {
        while let task = queue {
            await task.value
            if queue == task { return }
        }
    }

    func enqueue(_ action: @escaping (AppController) async throws -> Void, onError: @escaping (Error) -> Void) {
        queuedActions += 1
        let previous = queue
        queue = Task {
            await previous?.value
            defer { queuedActions -= 1 }
            do {
                try await action(self)
                lastError = nil
            } catch {
                cycle = nil
                onError(error)
            }
        }
    }

    // MARK: - Switching

    private func handleSwitchShortcut() {
        if safariActive {
            if hudController.isActive || hudController.isEnabled {
                hudController.pressSwitch()
            } else {
                perform { try await $0.switchProfile() }
            }
            return
        }
        switch settings.outsideSafariAction {
        case .showSwitcher where hudController.isActive || hudController.isEnabled:
            hudController.pressSwitch(outsideSafari: true)
        case .switchProfile where safari.isRunning:
            safari.activate()
            perform { try await $0.switchProfile() }
        case .activateSafari, .switchProfile, .showSwitcher:
            showLastWindow()
        case .passThrough:
            // Not registered outside Safari; a press can still arrive while the front app changes.
            break
        }
    }

    /// Back to Safari from another app: the window that was in front when Safari was left (the one the
    /// menu bar badge shows), even if it's minimized or another Safari window got in front meanwhile.
    /// Launches Safari if needed.
    func showLastWindow() {
        perform { controller in
            // Read when asked (not when Safari is left: no Apple Event to a Safari that may be quitting).
            // Safari's focused window stays the last one used while another app is in front.
            guard controller.safari.isRunning, let id = controller.safari.focusedWindowID() else {
                // Launches or activates Safari; "opening" a running app also makes it reopen a window.
                try await controller.safari.reopen()
                return
            }
            try controller.safari.focus(windowID: id)
            controller.safari.activate()
        }
    }

    func switchProfile() async throws {
        if settings.switchProfiles.count < 2 {
            refreshProfiles()
        }
        let windows = try safari.windows()
        guard let plan = Switcher.decide(
            windows: windows, profiles: settings.switchProfiles, cycle: cycle, closeEmpty: settings.closeEmptyWindow)
        else {
            throw AppError(String(localized: "Choose at least two profiles in Settings"))
        }
        try await apply(plan, windows: windows)
    }

    /// Carries out a switch: focuses (and aligns) or opens the window, closes the empty one.
    func apply(_ plan: SwitchPlan, windows: [SafariWindow]) async throws {
        cycle = plan.cycle
        let front = windows.first
        switch plan.target {
        case .focus(let windowID):
            if settings.alignExistingWindows, let front, let target = windows.first(where: { $0.id == windowID }),
               profile(of: front) != profile(of: target) {
                try align(windowID, with: front.id)
            }
            try safari.focus(windowID: windowID)
        case .openNew(let profile):
            _ = try await openNewWindow(profile: profile, replacing: front?.id)
        }
        if let closeID = plan.closeWindowID {
            try safari.close(windowID: closeID)
        }
    }

    /// Opens a new window of `profile` and, with "in place", gives it the frame (or full screen) of `source`.
    /// - Returns: the new window's id.
    func openNewWindow(profile: String, replacing source: Int?) async throws -> Int {
        let known = Set(try safari.windows().map(\.id))
        var frame: CGRect?
        var fullScreen = false
        if settings.newWindowInPlace, let source {
            fullScreen = safari.isFullScreen(windowID: source)
            frame = try safari.bounds(windowID: source)
        }
        try safari.openNewWindow(profile: profile)
        let newID = try await safari.waitForNewWindow(excluding: known)
        if fullScreen {
            // A full-screen frame makes no sense for a window on the desktop, so either match or leave it.
            if settings.matchFullScreen { safari.setFullScreen(windowID: newID) }
        } else if let frame {
            try safari.setBounds(frame, windowID: newID)
        }
        return newID
    }

    /// Moves `windowID` onto `reference`'s frame, unless either is full screen.
    private func align(_ windowID: Int, with reference: Int) throws {
        guard !safari.isFullScreen(windowID: reference), !safari.isFullScreen(windowID: windowID),
              let frame = try safari.bounds(windowID: reference)
        else { return }
        try safari.setBounds(frame, windowID: windowID)
    }

    func profile(of window: SafariWindow) -> String? {
        ProfileMatcher.profile(of: window, among: knownProfiles)
    }

    // MARK: - Tabs

    /// Opens the current tab's URL in the next profile (or the one a link rule picks, or `profile`) and
    /// closes the tab.
    func moveTabToOtherProfile(_ profile: String? = nil) async throws {
        let tab = try safari.currentTab()
        let windows = try safari.windows()
        let result = TabTransfer.plan(
            tab: tab, windows: windows, profiles: settings.switchProfiles,
            preferredProfile: preferredProfile(for: tab.url), explicitProfile: profile, keepSource: settings.keepSourceTab)
        let plan: TabTransferPlan
        switch result {
        case .success(let value): plan = value
        case .failure(.profilesNotConfigured):
            throw AppError(String(localized: "Choose at least two profiles in Settings"))
        case .failure(.nothingToMove):
            throw AppError(String(localized: "Nothing to move: the tab shows the start page"))
        case .failure(.alreadyInProfile):
            throw AppError(String(localized: "The tab is already in this profile"))
        }
        // Open first, close after: a failure must never lose the tab.
        switch plan.target {
        case .window(let id):
            try safari.openTab(url: tab.url, windowID: id)
            try safari.focus(windowID: id)
        case .newWindow(let profile):
            let id = try await openNewWindow(profile: profile, replacing: tab.windowID)
            try safari.setCurrentTabURL(tab.url, windowID: id)
        }
        switch plan.cleanup {
        case .none: break
        case .closeTab(let windowID, let index): try safari.closeTab(index: index, windowID: windowID)
        case .closeWindow(let id): try safari.close(windowID: id)
        }
        cycle = nil
        if let host = URL(string: tab.url)?.host() {
            lastTransfer = (host, plan.profile)
        }
    }

    /// Moves the current tab into a new window of its profile, keeping its history.
    func detachTab() async throws {
        let tab = try safari.currentTab()
        guard tab.tabCount > 1 else {
            throw AppError(String(localized: "The tab is already alone in its window"))
        }
        let known = Set(try safari.windows().map(\.id))
        let newID: Int
        if try safari.moveCurrentTabToNewWindow() {
            newID = try await safari.waitForNewWindow(excluding: known)
        } else {
            // No "Move Tab to New Window" item: open a window of the profile and move the tab there.
            guard let profile = tab.isPrivate ? ProfileMatcher.privateProfile
                    : ProfileMatcher.profile(ofTitle: tab.windowTitle, among: knownProfiles) else {
                throw AppError(String(localized: "Can't tell the profile of this window"))
            }
            newID = try await openNewWindow(profile: profile, replacing: nil)
            try safari.moveTab(index: tab.index, from: tab.windowID, to: newID)
            try safari.closeTab(index: 1, windowID: newID)
        }
        settings.detachedFrom[newID] = tab.windowID
    }

    /// Moves the current tab back into the window it was detached from (or another window of its profile).
    /// A window left without tabs closes by itself.
    func attachTab() async throws {
        let tab = try safari.currentTab()
        let windows = try safari.windows()
        guard let target = TabAttach.target(
            windows: windows, sourceWindowID: tab.windowID, profiles: knownProfiles,
            detachedFrom: settings.detachedFrom[tab.windowID])
        else {
            throw AppError(String(localized: "No other window of this profile"))
        }
        try safari.moveTab(index: tab.index, from: tab.windowID, to: target)
        try safari.focus(windowID: target)
        var detached = settings.detachedFrom
        if tab.tabCount <= 1 {
            detached[tab.windowID] = nil
        }
        let open = Set(windows.map(\.id))
        settings.detachedFrom = detached.filter { open.contains($0.key) && open.contains($0.value) }
    }

    // MARK: - Menu actions

    /// Brings a window to the front and activates Safari (from the menu bar list).
    func showWindow(id: Int) {
        perform { controller in
            try controller.safari.focus(windowID: id)
            controller.safari.activate()
        }
    }

    func openWindow(profile: String) {
        perform {
            try await $0.safari.launch()
            $0.safari.activate()
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

    struct AppError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Switcher HUD

    /// Shows the HUD's choice: a window, or a profile's front-most window (a new one if it has none).
    /// - Parameter tab: a tab (0-based) chosen in the window's row, to make current.
    func activate(_ item: HUDItem, windows: [SafariWindow], tab: Int? = nil) async throws {
        var windows = windows
        cycle = nil
        if !safari.isRunning {
            // From another app with Safari quit: launch it and work with the windows it opens by itself.
            try await safari.launch()
            windows = try safari.windows()
        }
        let front = windows.first
        var target: SafariWindow?
        switch item.target {
        case .window(let id):
            target = windows.first { $0.id == id }
        case .profile(let profile):
            target = front.flatMap { self.profile(of: $0) == profile ? $0 : nil }
                ?? windows.first { self.profile(of: $0) == profile }
            if target == nil {
                _ = try await openNewWindow(profile: profile, replacing: front?.id)
            }
        }
        if let target, let tab, tab != item.currentTab {
            try safari.selectTab(index: tab + 1, windowID: target.id)
        }
        if let target, target.id != front?.id {
            if settings.alignExistingWindows, let front, profile(of: front) != profile(of: target) {
                try align(target.id, with: front.id)
            }
            try safari.focus(windowID: target.id)
        }
        if target?.id != front?.id, settings.closeEmptyWindow, let front, front.isEmptyStartPage,
           profile(of: front) != nil {
            try safari.close(windowID: front.id)
        }
        safari.activate()
    }

    func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        lastError = message
        NSSound.beep()
    }

    // MARK: - Profiles

    private func updateCurrentProfile() {
        guard safari.isRunning else { return }
        let title = observer.focusedWindowTitle() ?? ""
        let profile = ProfileMatcher.isPrivate(title: title, realProfiles: detectedProfiles)
            ? ProfileMatcher.privateProfile : ProfileMatcher.profile(ofTitle: title, among: knownProfiles)
        if profile != currentProfile, !title.isEmpty {
            currentProfile = profile
        }
    }

    /// Detects profiles from Safari; with fewer than two to switch between, switches between all of them.
    func refreshProfiles() {
        guard safari.isRunning else { return }
        detectedProfiles = safari.detectProfiles()
        if settings.switchProfiles.count < 2 {
            settings.switchProfiles = ProfileMatcher.cleaned(settings.switchProfiles + detectedProfiles)
        }
        updateProfileWarnings()
    }

    /// Checks the settings against Safari's profiles.
    func updateProfileWarnings() {
        let warnings = ProfileHealth.warnings(used: settings.usedProfiles, detected: detectedProfiles)
        if warnings != profileWarnings { profileWarnings = warnings }
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

extension ProfileWarning {
    var message: String {
        switch self {
        case .missingProfile(let profile):
            String(localized: "Profile “\(profile)” is not in Safari: renamed or deleted?")
        }
    }
}
