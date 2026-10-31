import AppKit
import SwitcherCore

/// Drives the switcher HUD: feeds presses and the modifier state to `HUDKeySession` (the decisions, tested
/// in SwitcherCore) and shows, moves and hides the panel accordingly.
@MainActor
final class HUDController {
    let hud = SwitcherHUD()
    var knownProfiles: () -> [String] = { [] }
    /// Safari actions are queued: windows read now could be stale by the time the HUD shows.
    var isBusy: () -> Bool = { false }
    /// Released before the HUD appeared; `true` if the press came while another app was in front.
    var onSwitchNow: (_ outsideSafari: Bool) -> Void = { _ in }
    /// The selection was confirmed: the item, the windows listed when the HUD opened, and the tab chosen
    /// in the window's row (0-based), if tabs are shown.
    var onActivate: (HUDItem, [SafariWindow], Int?) -> Void = { _, _, _ in }
    /// A session started or ended, or the HUD appeared: the HUD's shortcuts are registered from the first
    /// press on (so ⌥⇧⇥ goes back even before the HUD shows), and the Safari ones only without a session.
    var onVisibilityChange: () -> Void = {}
    /// Something to do with the selected tab or window (the HUD is closed first).
    var onAction: (SelectionAction) -> Void = { _ in }

    enum SelectionAction: Equatable {
        case moveTab(windowID: Int, tab: Int?)
        case detachTab(windowID: Int, tab: Int?)
        case moveWindow(windowID: Int)
    }

    /// What the close shortcuts close.
    enum CloseTarget {
        case tab, window
    }
    var onError: (String) -> Void = { _ in }

    private let settings: AppSettings
    private let safari: SafariAPI
    private var session: HUDKeySession
    /// Polls the modifiers from the first press of the switch shortcut until they are released.
    private var timer: Timer?
    private var state: HUDState?
    /// The session started while another app was in front.
    private var outsideSafari = false
    /// Safari windows when the HUD opened, front-most first.
    private var windows: [SafariWindow] = []
    /// What a close shortcut was pressed on once, and when; a second press soon after closes it.
    private var pendingClose: (target: CloseTarget, windowID: Int, tab: Int?, at: Double)?
    /// Windows and tabs read at the first press, while the modifier is held; the HUD shows them at once.
    private var prefetched: (windows: [SafariWindow], tabs: [Int: WindowTabs], at: Double)?
    private static let closeConfirmation = 2.0

    init(settings: AppSettings, safari: SafariAPI) {
        self.settings = settings
        self.safari = safari
        session = HUDKeySession(delay: settings.hudDelay)
    }

    var isVisible: Bool { hud.isVisible }

    /// A press is being tracked or the HUD is shown.
    var isActive: Bool { session.isActive || hud.isVisible }

    /// Whether presses of the switch shortcut go through the HUD (it needs a modifier to hold).
    var isEnabled: Bool { settings.hudMode != .off && !holdFlags.isEmpty }

    /// A press of the switch shortcut, in Safari or (with "show the switcher") in another app.
    func pressSwitch(outsideSafari: Bool = false) {
        let starting = !session.isActive
        if starting {
            session.delay = settings.hudDelay
            self.outsideSafari = outsideSafari
        }
        apply(session.press(at: Self.now))
        if starting {
            onVisibilityChange()
            if session.isActive && !hud.isVisible { prefetch() }
        }
    }

    /// The switch shortcut with Shift.
    func pressBack() {
        apply(session.pressBack(at: Self.now))
    }

    func step(_ direction: HUDState.Direction) {
        update { $0.step(direction) }
    }

    /// Closes the selected tab (or its whole window) on the second press within two seconds; the first
    /// press marks it in red.
    func closeSelected(_ target: CloseTarget) {
        guard hud.isVisible, let state, case .window(let id)? = state.selected?.target else { return }
        let tab = target == .tab ? state.selectedTab : nil
        if target == .tab && tab == nil { return }
        if let pending = pendingClose, pending.target == target, pending.windowID == id, pending.tab == tab,
           Self.now - pending.at < Self.closeConfirmation {
            setPendingClose(nil)
            do {
                if let tab {
                    try safari.closeTab(index: tab + 1, windowID: id)
                } else {
                    try safari.close(windowID: id)
                }
                reload(selecting: id, tab: tab ?? 0)
            } catch {
                onError(error.localizedDescription)
            }
        } else {
            setPendingClose((target, id, tab, Self.now))
        }
    }

    enum SelectionCommand {
        case moveTab, detachTab, moveWindow
    }

    /// Closes the HUD and hands the selected tab or window to `onAction`.
    func runOnSelection(_ command: SelectionCommand) {
        guard hud.isVisible, let state, case .window(let id)? = state.selected?.target else { return }
        let tab = state.selectedTab
        close(confirm: false)
        switch command {
        case .moveTab: onAction(.moveTab(windowID: id, tab: tab))
        case .detachTab: onAction(.detachTab(windowID: id, tab: tab))
        case .moveWindow: onAction(.moveWindow(windowID: id))
        }
    }

    private func update(_ change: (inout HUDState) -> Void) {
        guard hud.isVisible, var state else { return }
        change(&state)
        self.state = state
        setPendingClose(nil)
        hud.update(state)
    }

    private func setPendingClose(_ pending: (target: CloseTarget, windowID: Int, tab: Int?, at: Double)?) {
        pendingClose = pending
        hud.model.pendingClose = pending?.target
    }

    /// Reads windows and tabs right after the first press, so the HUD needn't wait for Safari when it shows.
    /// (Still on the main thread, as all AppleScript here: a moment after the key event, during the delay.)
    private func prefetch() {
        prefetched = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session.isActive, !self.hud.isVisible, !self.isBusy(),
                      let windows = try? self.safari.windows() else { return }
                self.prefetched = (windows, (try? self.safari.tabs()) ?? [:], Self.now)
            }
        }
    }

    /// Lists the windows (and tabs) again after a tab was closed, keeping the selection on that window.
    private func reload(selecting windowID: Int, tab: Int) {
        guard var state = try? makeState() else { return }
        state.select(windowID: windowID, tab: tab)
        if !state.items.contains(where: { $0.target == .window(id: windowID) }) {
            // The window closed with its last tab: stay at the same place in the list.
            state.select(min(self.state?.selection ?? 0, state.items.count - 1))
        }
        self.state = state
        hud.update(state)
    }

    /// The HUD's items for the current windows; the window list also shows the tabs.
    private func makeState(usePrefetched: Bool = false) throws -> HUDState {
        let windows: [SafariWindow]
        let tabs: [Int: WindowTabs]
        if usePrefetched, let prefetched, Self.now - prefetched.at < 2 {
            (windows, tabs) = (prefetched.windows, prefetched.tabs)
        } else {
            windows = try safari.windows()
            tabs = (try? safari.tabs()) ?? [:]
        }
        prefetched = nil
        self.windows = windows
        let profiles = knownProfiles()
        return settings.hudMode == .windows
            ? HUDState.windows(windows: windows, profiles: profiles, tabs: tabs)
            : HUDState.profiles(windows: windows, profiles: profiles, tabs: tabs)
    }

    func cancel() {
        guard isActive else { return }
        close(confirm: false)
    }

    /// Modifiers of the switch shortcut; the HUD stays open while they are held.
    private var holdFlags: NSEvent.ModifierFlags { settings.shortcuts[.switchProfile]?.holdFlags ?? [] }

    private func apply(_ effect: HUDKeySession.Effect) {
        switch effect {
        case .none: break
        case .show(let extraPresses): show(extraPresses: extraPresses)
        case .moveSelection(let offset): update { $0.step(by: offset) }
        case .switchNow:
            stopTimer()
            prefetched = nil
            onVisibilityChange()
            onSwitchNow(outsideSafari)
        case .confirm: close(confirm: true)
        }
        if session.isActive && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        apply(session.tick(modifiersHeld: Self.modifiersHeld(holdFlags), at: Self.now))
    }

    private func show(extraPresses: Int) {
        guard !hud.isVisible else { return }
        do {
            var state = try makeState(usePrefetched: true)
            state.step(by: extraPresses)
            self.state = state
            let profiles = knownProfiles()
            hud.model.look = { [settings] profile in profile.map { settings.look(for: $0, among: profiles) } ?? .unknown }
            hud.model.onClick = { [weak self] index, tab in
                self?.state?.select(index)
                if let tab, case .window(let id)? = self?.state?.selected?.target {
                    self?.state?.select(windowID: id, tab: tab)
                }
                self?.close(confirm: true)
            }
            setPendingClose(nil)
            let frame = windows.first.flatMap { try? safari.bounds(windowID: $0.id) }
            hud.show(state, near: frame)
            onVisibilityChange()
        } catch {
            session.reset()
            stopTimer()
            onError(error.localizedDescription)
        }
    }

    private func close(confirm: Bool) {
        session.reset()
        stopTimer()
        let selected = state?.selected
        let tab = state?.selectedTab
        let windows = self.windows
        setPendingClose(nil)
        hud.hide()
        state = nil
        prefetched = nil
        self.windows = []
        onVisibilityChange()
        guard confirm, let selected else { return }
        onActivate(selected, windows, tab)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

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
}
