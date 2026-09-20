import XCTest
@testable import JotCore

final class DictationShortcutTests: XCTestCase {
    private let chord = DictationShortcut(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")

    func testCustomChordStartsOnceAndConsumesRepeatAndRelease() {
        var tracker = ShortcutTracker()
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1), .init(action: .start, consume: true))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, repeating: true, shortcut: chord, at: 1.1), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1.4), .init(action: .stop, consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord, at: 1.5), .init())
    }

    func testReleasingModifiersFirstStopsOnceAndStillConsumesKeyUp() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 58, modifiers: [.control], shortcut: chord, at: 1.4).action, .stop)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [], repeating: true, shortcut: chord, at: 1.5), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord, at: 1.6), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 2).action, .start)
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
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn), .init(action: .discardTap))
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

    func testShortTapDiscardsWithoutStopping() {
        var tracker = ShortcutTracker()
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 10).action, .start)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 10.2).action, .discardTap)
    }

    func testShortTapClassificationUsesSuppliedPhysicalEventTimestamps() {
        var tracker = ShortcutTracker()
        // Event handling may pause for Accessibility target discovery between these
        // calls. Classification depends only on the supplied event times.
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 20)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 20.1).action, .discardTap)
    }

    func testTwoShortTapsRecoverAndThirdTapStartsANewSequence() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.1).action, .discardTap)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.4).action, .start)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.5).action, .recover)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.7).action, .start)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.8).action, .discardTap)
    }

    func testHoldLongerThanSixtySecondsIsAnOrdinaryStop() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 5)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 70).action, .stop)
    }

    func testSecondLongHoldDoesNotPreemptRecovery() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.1)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.3).action, .start)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 2).action, .stop)
    }

    func testUnrelatedKeyAndResetInvalidateDoubleTapSequence() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.1)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 0, modifiers: [], shortcut: .fn, at: 1.2), .init())
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.3)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.4).action, .discardTap)

        tracker.reset()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.5)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.6).action, .discardTap)
    }

    func testCancellationInvalidatesDoubleTapSequence() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.1)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.2)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 0, modifiers: [.fn], shortcut: .fn, at: 1.25).action, .cancel)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.3)
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1.4)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.5).action, .discardTap)
    }

    func testFnKeyGhostAndRepeatDoNotCancelOrCreateExtraActions() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], shortcut: .fn, at: 1)
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 63, modifiers: [.fn], repeating: true, shortcut: .fn, at: 1.05), .init())
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 55, modifiers: [.fn], shortcut: .fn, at: 1.1), .init())
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 63, modifiers: [], shortcut: .fn, at: 1.3).action, .stop)
    }

    func testConfiguredShortcutAlsoSupportsDoubleTapAndModifierRelease() {
        var tracker = ShortcutTracker()
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1)
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1.1).action, .discardTap)
        _ = tracker.handle(.keyDown, keyCode: 49, modifiers: chord.modifiers, shortcut: chord, at: 1.3)
        XCTAssertEqual(tracker.handle(.flagsChanged, keyCode: 58, modifiers: [.control], shortcut: chord, at: 1.4).action, .recover)
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], shortcut: chord, at: 1.5), .init(consume: true))
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
