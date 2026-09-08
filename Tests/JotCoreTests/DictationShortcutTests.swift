import XCTest
@testable import JotCore

final class DictationShortcutTests: XCTestCase {
    private let chord = DictationShortcut(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")

    func testCustomChordStartsOnceAndConsumesRepeatAndRelease() {
        var tracker = ShortcutTracker()
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord), .init(action: .start, consume: true))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, repeating: true, shortcut: chord), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: chord.modifiers, shortcut: chord), .init(action: .stop, consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord), .init())
    }

    func testReleasingModifiersFirstStopsOnceAndStillConsumesKeyUp() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 58, modifiers: [.control], shortcut: chord).action, .stop)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [], repeating: true, shortcut: chord), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord).action, .start)
    }

    func testUnrelatedKeyCancelsWithoutSwallowingItOrRestarting() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 0, modifiers: chord.modifiers, shortcut: chord), .init(action: .cancel))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, repeating: true, shortcut: chord), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord), .init(consume: true))
    }

    func testAddedModifierCancelsInsteadOfInserting() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 56, modifiers: [.control, .option, .shift], shortcut: chord).action, .cancel)
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord), .init(consume: true))
    }

    func testOtherShortcutsPlainTypingAndAnOrphanRepeatPassThrough() {
        var tracker = ShortcutTracker()
        for modifiers: ShortcutModifiers in [[], [.control], [.control, .option, .command]] {
            XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: modifiers, shortcut: chord), .init())
        }
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, repeating: true, shortcut: chord), .init())
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 0, modifiers: chord.modifiers, shortcut: chord), .init())
    }

    func testFnStillPassesThroughAndNavigationFlagsCannotStartIt() {
        var tracker = ShortcutTracker()
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 123, modifiers: [.fn], shortcut: .fn), .init())
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn), .init(action: .start))
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn), .init())
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn), .init(action: .stop))
    }

    func testFnCombinationCancelsAndCannotRestartWhileHeld() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 123, modifiers: [.fn], shortcut: .fn).action, .cancel)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn).action, .none)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn, .command], shortcut: .fn).action, .cancel)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 55, modifiers: [.fn], shortcut: .fn).action, .none)
    }

    func testPreferencesPersistAndInvalidOrMissingValuesFallBackToFn() throws {
        let suite = "JotShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(preferences.load(), .fn)
        try preferences.save(chord)
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).load(), chord)
        XCTAssertEqual(chord.displayName, "⌃⌥Space")
        let invalid = DictationShortcut(keyCode: 0, modifiers: [.shift], keyLabel: "A")
        XCTAssertThrowsError(try preferences.save(invalid))
        XCTAssertEqual(preferences.load(), chord)
        defaults.set(try JSONEncoder().encode(invalid), forKey: "dictationShortcut")
        XCTAssertEqual(preferences.load(), .fn)
        defaults.set(Data("broken".utf8), forKey: "dictationShortcut")
        XCTAssertEqual(preferences.load(), .fn)
        try preferences.save(.fn)
        XCTAssertEqual(preferences.load(), .fn)
    }
}
