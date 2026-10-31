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

    /// Settings or Safari state that keep profiles from working as configured.
    @Published private(set) var profileWarnings: [ProfileWarning] = []

    private let hotKey = HotKeyManager()
    private let hudController: HUDController
    var hud: SwitcherHUD { hudController.hud }
    private let observer = SafariObserver()
    /// Safari is the front app.
    @Published private(set) var safariActive =
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SafariController.bundleID
    private var hotKeyPaused = false
    /// Windows already shown in the current round of cycling through a profile.
    private var cycle: CycleState?
    /// The last queued Safari action; the next one waits for it.
    private var queue: Task<Void, Never>?
    /// Queued Safari actions, including the running one.
    private var queuedActions = 0
    /// The last tab moved to another profile, offered as a link rule in the menu.
    @Published private(set) var lastTransfer: (host: String, profile: String)?
    private var cancellables: Set<AnyCancellable> = []

    init(customSettings: AppSettings? = nil, promptForAccessibility: Bool = true) {
        settings = customSettings ?? AppSettings()
        hudController = HUDController(settings: settings)
        hudController.knownProfiles = { [weak self] in self?.knownProfiles ?? [] }
        hudController.onSwitchNow = { [weak self] outsideSafari in
            // Like a quick ⌘⇥: from another app, just go to Safari; in Safari, switch the profile.
            if outsideSafari { self?.openSafari() } else { self?.perform { try await $0.switchProfile() } }
        }
        hudController.onActivate = { [weak self] item, windows in
            self?.perform { try await $0.activate(item, windows: windows) }
        }
        hudController.onVisibilityChange = { [weak self] in self?.updateHotKeyRegistration() }
        hudController.onError = { [weak self] in self?.fail($0) }
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

    var profilesSummary: String {
        settings.switchProfiles.count < 2 ? String(localized: "Choose profiles in Settings")
            : settings.switchProfiles.map(ProfileMatcher.displayName).joined(separator: " → ")
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

    private func frontAppChanged(isSafari: Bool) {
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
    private func updateHotKeyRegistration() {
        var bindings: [ShortcutAction: Shortcut] = [:]
        if hotKeyPaused {
            bindings = [:]
        } else if hudController.isActive {
            bindings = settings.shortcuts.filter { $0.key.scopes.contains(.hud) }
            // ⌥⇧⇥ goes back, unless the user gave those keys to a switcher action.
            if let back = ShortcutAction.switchBack(for: settings.shortcuts[.switchProfile]),
               !bindings.values.contains(back) {
                bindings[.switchBack] = back
            }
        } else if safariActive {
            bindings = settings.shortcuts.filter { $0.key.scopes.contains(.safari) }
        } else if settings.outsideSafariAction != .passThrough {
            bindings[.switchProfile] = settings.shortcuts[.switchProfile]
        }
        hotKey.apply(bindings)
        // Show only failures of the shortcuts as they are set now.
        hotKeyFailures = hotKey.failures.reduce(into: [:]) { result, failure in
            guard failure.key.isConfigurable, settings.shortcuts[failure.key] == failure.value.shortcut else { return }
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
            hudController.step(.next)
        case .hudPrevious:
            hudController.step(.previous)
        case .hudUp:
            hudController.step(.up)
        case .hudDown:
            hudController.step(.down)
        case .switchBack:
            hudController.pressBack()
        case .hudCancel:
            hudController.cancel()
        }
    }

    /// Queues an action from a shortcut or the menu. One action may wait behind the running one (a quick
    /// double press switches twice); further presses are dropped with a beep, so they don't pile up while
    /// Safari is slow.
    private func perform(_ action: @escaping (AppController) async throws -> Void) {
        guard queuedActions < 2 else {
            NSSound.beep()
            return
        }
        enqueue(action) { [weak self] error in self?.fail(error.localizedDescription) }
    }

    /// Runs Safari actions one after another, so one never interleaves with another that waits on Safari
    /// (e.g. two of them opening windows and each taking the other's new window for its own).
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
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SafariController.bundleID {
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
        case .switchProfile where SafariController.runningApp != nil:
            SafariController.runningApp?.activate()
            perform { try await $0.switchProfile() }
        case .activateSafari, .switchProfile, .showSwitcher:
            openSafari()
        case .passThrough:
            // Not registered outside Safari; a press can still arrive while the front app changes.
            break
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
        if settings.switchProfiles.count < 2 {
            refreshProfiles()
        }
        let windows = try SafariController.windows()
        guard let plan = Switcher.decide(
            windows: windows, profiles: settings.switchProfiles, cycle: cycle, closeEmpty: settings.closeEmptyWindow)
        else {
            throw AppError(String(localized: "Choose at least two profiles in Settings"))
        }
        cycle = plan.cycle
        let front = windows.first
        switch plan.target {
        case .focus(let windowID):
            if settings.alignExistingWindows, let front, let target = windows.first(where: { $0.id == windowID }),
               profile(of: front) != profile(of: target) {
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
    func openNewWindow(profile: String, replacing source: Int?) async throws -> Int {
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

    func profile(of window: SafariWindow) -> String? {
        ProfileMatcher.profile(of: window, among: knownProfiles)
    }

    // MARK: - Tabs

    /// Opens the current tab's URL in the other profile (or the one a link rule picks) and closes the tab.
    func moveTabToOtherProfile() async throws {
        let tab = try SafariController.currentTab()
        let windows = try SafariController.windows()
        let result = TabTransfer.plan(
            tab: tab, windows: windows, profiles: settings.switchProfiles,
            preferredProfile: preferredProfile(for: tab.url), keepSource: settings.keepSourceTab)
        let plan: TabTransferPlan
        switch result {
        case .success(let value): plan = value
        case .failure(.profilesNotConfigured):
            throw AppError(String(localized: "Choose at least two profiles in Settings"))
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
            guard let profile = tab.isPrivate ? ProfileMatcher.privateProfile
                    : ProfileMatcher.profile(ofTitle: tab.windowTitle, among: knownProfiles) else {
                throw AppError(String(localized: "Can't tell the profile of this window"))
            }
            newID = try await openNewWindow(profile: profile, replacing: nil)
            try SafariController.moveTab(index: tab.index, from: tab.windowID, to: newID)
            try SafariController.closeTab(index: 1, windowID: newID)
        }
        settings.detachedFrom[newID] = tab.windowID
    }

    /// Moves the current tab back into the window it was detached from (or another window of its profile).
    /// A window left without tabs closes by itself.
    func attachTab() async throws {
        let tab = try SafariController.currentTab()
        let windows = try SafariController.windows()
        guard let target = TabAttach.target(
            windows: windows, sourceWindowID: tab.windowID, profiles: knownProfiles,
            detachedFrom: settings.detachedFrom[tab.windowID])
        else {
            throw AppError(String(localized: "No other window of this profile"))
        }
        try SafariController.moveTab(index: tab.index, from: tab.windowID, to: target)
        try SafariController.focus(windowID: target)
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
        perform { _ in
            try SafariController.focus(windowID: id)
            SafariController.runningApp?.activate()
        }
    }

    func openWindow(profile: String) {
        perform {
            try await $0.launchSafariIfNeeded()
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

    struct AppError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Switcher HUD

    /// Shows the HUD's choice: a window, or a profile's front-most window (a new one if it has none).
    func activate(_ item: HUDItem, windows: [SafariWindow]) async throws {
        var windows = windows
        cycle = nil
        if SafariController.runningApp == nil {
            // From another app with Safari quit: launch it and work with the windows it opens by itself.
            try await launchSafariIfNeeded()
            windows = try SafariController.windows()
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
        if let target, target.id != front?.id {
            if settings.alignExistingWindows, let front, profile(of: front) != profile(of: target) {
                try align(target.id, with: front.id)
            }
            try SafariController.focus(windowID: target.id)
        }
        if target?.id != front?.id, settings.closeEmptyWindow, let front, front.isEmptyStartPage,
           profile(of: front) != nil {
            try SafariController.close(windowID: front.id)
        }
        SafariController.runningApp?.activate()
    }

    func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        lastError = message
        NSSound.beep()
    }

    // MARK: - Profiles

    private func updateCurrentProfile() {
        guard SafariController.runningApp != nil else { return }
        let title = observer.focusedWindowTitle() ?? ""
        let profile = ProfileMatcher.isPrivate(title: title, realProfiles: detectedProfiles)
            ? ProfileMatcher.privateProfile : ProfileMatcher.profile(ofTitle: title, among: knownProfiles)
        if profile != currentProfile, !title.isEmpty {
            currentProfile = profile
        }
    }

    /// Detects profiles from Safari; with fewer than two to switch between, switches between all of them.
    func refreshProfiles() {
        guard SafariController.runningApp != nil else { return }
        detectedProfiles = SafariController.detectProfiles()
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
