import XCTest
@testable import SwitcherCore

final class ShortcutTests: XCTestCase {
    func testConflictsOnlyWithinSharedScope() {
        let bindings: [ShortcutAction: String] = [.switchProfile: "⌥⇥", .moveTabToOtherProfile: "⌥⇧⇥", .hudPrevious: "⌥⇧⇥"]
        // Move tab (Safari) and HUD previous (HUD) are never active together.
        XCTAssertNil(ShortcutConflicts.conflict(for: .hudPrevious, key: "⌥⇧⇥", in: bindings))
        // The switch shortcut is active in both scopes.
        XCTAssertEqual(ShortcutConflicts.conflict(for: .hudNext, key: "⌥⇥", in: bindings), .switchProfile)
        XCTAssertEqual(ShortcutConflicts.conflict(for: .detachTab, key: "⌥⇥", in: bindings), .switchProfile)
        XCTAssertNil(ShortcutConflicts.conflict(for: .switchProfile, key: "⌥⇥", in: bindings))
    }

    func testAssignSwapsWithConflictingAction() {
        var bindings: [ShortcutAction: String] = [.detachTab: "⌥⇧↑", .attachTab: "⌥⇧↓"]
        let changed = ShortcutConflicts.assign("⌥⇧↓", to: .detachTab, in: &bindings)
        XCTAssertEqual(changed, .attachTab)
        XCTAssertEqual(bindings, [.detachTab: "⌥⇧↓", .attachTab: "⌥⇧↑"])
    }

    func testAssignUnbindsWhenSwapWouldClash() {
        // detachTab had no key, so attachTab can't take it over and gets unbound.
        var bindings: [ShortcutAction: String] = [.attachTab: "⌥⇧↓"]
        XCTAssertEqual(ShortcutConflicts.assign("⌥⇧↓", to: .detachTab, in: &bindings), .attachTab)
        XCTAssertEqual(bindings, [.detachTab: "⌥⇧↓"])
    }

    func testAssignWithoutConflictAndUnbind() {
        var bindings: [ShortcutAction: String] = [.switchProfile: "⌥⇥"]
        XCTAssertNil(ShortcutConflicts.assign("⌥⇧⇥", to: .moveTabToOtherProfile, in: &bindings))
        XCTAssertNil(ShortcutConflicts.assign(nil, to: .switchProfile, in: &bindings))
        XCTAssertEqual(bindings, [.moveTabToOtherProfile: "⌥⇧⇥"])
    }
}
