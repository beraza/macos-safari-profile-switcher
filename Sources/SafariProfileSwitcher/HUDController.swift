import AppKit
import SwitcherCore

/// Drives the switcher HUD: feeds presses and the modifier state to `HUDKeySession` (the decisions, tested
/// in SwitcherCore) and shows, moves and hides the panel accordingly.
@MainActor
final class HUDController {
    let hud = SwitcherHUD()
    var knownProfiles: () -> [String] = { [] }
    /// Released before the HUD appeared.
    var onSwitchNow: () -> Void = {}
    /// The selection was confirmed; the windows are those listed when the HUD opened.
    var onActivate: (HUDItem, [SafariWindow]) -> Void = { _, _ in }
    /// The HUD appeared or went away (the HUD's shortcuts are registered only while it is shown).
    var onVisibilityChange: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    private let settings: AppSettings
    private var session: HUDKeySession
    /// Polls the modifiers from the first press of the switch shortcut until they are released.
    private var timer: Timer?
    private var state: HUDState?
    /// Safari windows when the HUD opened, front-most first.
    private var windows: [SafariWindow] = []

    init(settings: AppSettings) {
        self.settings = settings
        session = HUDKeySession(delay: settings.hudDelay)
    }

    var isVisible: Bool { hud.isVisible }

    /// A press is being tracked or the HUD is shown.
    var isActive: Bool { session.isActive || hud.isVisible }

    /// Whether presses of the switch shortcut go through the HUD (it needs a modifier to hold).
    var isEnabled: Bool { settings.hudMode != .off && !holdFlags.isEmpty }

    func pressSwitch() {
        if !session.isActive { session.delay = settings.hudDelay }
        apply(session.press(at: Self.now))
    }

    func move(by offset: Int) {
        guard hud.isVisible, var state else { return }
        state.move(by: offset)
        self.state = state
        hud.update(state)
    }

    func cancel() {
        close(confirm: false)
    }

    /// Modifiers of the switch shortcut; the HUD stays open while they are held.
    private var holdFlags: NSEvent.ModifierFlags { settings.shortcuts[.switchProfile]?.holdFlags ?? [] }

    private func apply(_ effect: HUDKeySession.Effect) {
        switch effect {
        case .none: break
        case .show(let extraPresses): show(extraPresses: extraPresses)
        case .moveSelection(let offset): move(by: offset)
        case .switchNow:
            stopTimer()
            onSwitchNow()
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
            let windows = try SafariController.windows()
            let profiles = knownProfiles()
            var state = settings.hudMode == .windows
                ? HUDState.windows(windows: windows, profiles: profiles)
                : HUDState.profiles(windows: windows, profiles: profiles)
            state.move(by: extraPresses)
            self.state = state
            self.windows = windows
            hud.model.badge = { [settings] in settings.badge(for: $0) }
            hud.model.onClick = { [weak self] index in
                self?.state?.select(index)
                self?.close(confirm: true)
            }
            let frame = windows.first.flatMap { try? SafariController.bounds(windowID: $0.id) }
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
        let windows = self.windows
        let wasVisible = hud.isVisible
        hud.hide()
        state = nil
        self.windows = []
        if wasVisible { onVisibilityChange() }
        guard confirm, let selected else { return }
        onActivate(selected, windows)
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
