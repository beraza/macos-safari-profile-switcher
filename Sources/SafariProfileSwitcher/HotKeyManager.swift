import Carbon.HIToolbox
import SwitcherCore

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Input Monitoring permission needed).
/// Only the bindings passed to `apply` are registered, so keys aren't swallowed when they shouldn't be.
final class HotKeyManager {
    var onPress: ((ShortcutAction) -> Void)?

    /// Shortcuts that failed to register (e.g. taken by another app), kept until the action registers fine.
    private(set) var failures: [ShortcutAction: (shortcut: Shortcut, status: OSStatus)] = [:]

    private var registered: [ShortcutAction: (shortcut: Shortcut, ref: EventHotKeyRef)] = [:]
    private var handlerRef: EventHandlerRef?

    private static let signature = OSType(0x5350_5357) // 'SPSW'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let actions = ShortcutAction.allCases
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature,
                  hotKeyID.id >= 1, Int(hotKeyID.id) <= actions.count
            else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onPress?(actions[Int(hotKeyID.id) - 1])
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        apply([:])
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers exactly `bindings`: unregisters removed or changed ones first, so keys can be swapped.
    func apply(_ bindings: [ShortcutAction: Shortcut]) {
        for (action, entry) in registered where bindings[action] != entry.shortcut {
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = bindings[action], registered[action] == nil else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = (shortcut, ref)
                failures[action] = nil
            } else {
                log.error("RegisterEventHotKey \(action.rawValue, privacy: .public) failed: \(status)")
                failures[action] = (shortcut, status)
            }
        }
    }
}
