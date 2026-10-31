import Carbon.HIToolbox
import SwitcherCore

/// What a registered hotkey does: a configurable action, or a numbered profile shortcut.
enum HotKeyCommand: Hashable {
    case action(ShortcutAction)
    /// Go to the profile at this place (1…9) in the switching list.
    case goToProfile(Int)
    /// Move the current tab to the profile at this place.
    case moveTabToProfile(Int)

    /// Carbon hotkey id: actions from 1, profiles from 100, tab moves from 200.
    var id: UInt32 {
        switch self {
        case .action(let action): UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1)
        case .goToProfile(let number): UInt32(100 + number)
        case .moveTabToProfile(let number): UInt32(200 + number)
        }
    }

    init?(id: UInt32) {
        let actions = ShortcutAction.allCases
        switch id {
        case 1...UInt32(actions.count): self = .action(actions[Int(id) - 1])
        case 101...109: self = .goToProfile(Int(id) - 100)
        case 201...209: self = .moveTabToProfile(Int(id) - 200)
        default: return nil
        }
    }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Input Monitoring permission needed).
/// Only the bindings passed to `apply` are registered, so keys aren't swallowed when they shouldn't be.
final class HotKeyManager {
    var onPress: ((HotKeyCommand) -> Void)?

    /// Shortcuts that failed to register (e.g. taken by another app), kept until the command registers fine.
    private(set) var failures: [HotKeyCommand: (shortcut: Shortcut, status: OSStatus)] = [:]

    private var registered: [HotKeyCommand: (shortcut: Shortcut, ref: EventHotKeyRef)] = [:]
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
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature,
                  let command = HotKeyCommand(id: hotKeyID.id)
            else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onPress?(command)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        apply([:])
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers exactly `bindings`: unregisters removed or changed ones first, so keys can be swapped.
    func apply(_ bindings: [HotKeyCommand: Shortcut]) {
        for (command, entry) in registered where bindings[command] != entry.shortcut {
            UnregisterEventHotKey(entry.ref)
            registered[command] = nil
        }
        // Configurable actions first, so they win a key over the derived ones.
        for (command, shortcut) in bindings.sorted(by: { $0.key.id < $1.key.id }) where registered[command] == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.id)
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[command] = (shortcut, ref)
                failures[command] = nil
            } else {
                log.error("RegisterEventHotKey \(String(describing: command), privacy: .public) failed: \(status)")
                failures[command] = (shortcut, status)
            }
        }
    }
}
