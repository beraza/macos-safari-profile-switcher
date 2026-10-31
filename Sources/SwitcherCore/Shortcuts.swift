import Foundation

/// Everything that can be bound to a shortcut.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case switchProfile, moveTabToOtherProfile, detachTab, attachTab, hudNext, hudPrevious, hudCancel

    public var id: Self { self }

    public enum Scope: Sendable {
        /// While Safari is the front app.
        case safari
        /// While the switcher HUD is open.
        case hud
    }

    /// When the shortcut is registered. The switch shortcut also selects the next item in the HUD.
    public var scopes: Set<Scope> {
        switch self {
        case .switchProfile: [.safari, .hud]
        case .moveTabToOtherProfile, .detachTab, .attachTab: [.safari]
        case .hudNext, .hudPrevious, .hudCancel: [.hud]
        }
    }
}

public enum ShortcutConflicts {
    /// The action already bound to `key` that is active at the same time as `action`.
    public static func conflict<Key: Equatable>(
        for action: ShortcutAction, key: Key, in bindings: [ShortcutAction: Key]
    ) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && bindings[other] == key && !other.scopes.isDisjoint(with: action.scopes)
        }
    }

    /// Binds `key` to `action` (`nil` unbinds). A conflicting action gets `action`'s previous key if that
    /// doesn't clash with anything, otherwise it is unbound.
    /// - Returns: the action whose binding changed as a result, if any.
    @discardableResult
    public static func assign<Key: Equatable>(
        _ key: Key?, to action: ShortcutAction, in bindings: inout [ShortcutAction: Key]
    ) -> ShortcutAction? {
        let previous = bindings[action]
        bindings[action] = key
        guard let key, let other = conflict(for: action, key: key, in: bindings) else { return nil }
        if let previous, conflict(for: other, key: previous, in: bindings) == nil {
            bindings[other] = previous
        } else {
            bindings[other] = nil
        }
        return other
    }
}
