import Foundation
import JotCore

/// Pure state checks: these never install an event tap or touch a user's field.
enum ShortcutInputChecks {
    static func run() {
        let fn = ShortcutEventTap()
        fn.configure { $0.fnSuggestionsEnabled = true }
        precondition(fn.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 10).actions == [.start])
        // Main can be delayed by AX or storage; the tap must classify the physical
        // release from its timestamp before any start callback has run.
        precondition(fn.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [], at: 10.05).actions == [.discardTap])
        precondition(fn.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 10.2).actions == [.start])
        precondition(fn.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [], at: 10.25).actions == [.doubleTap])
        precondition(fn.decideForTesting(.keyDown, keyCode: 179, modifiers: [], at: 10.26) ==
            .init(consume: false, actions: []), "Fn companion key must pass through")

        let chord = ShortcutEventTap()
        let shortcut = DictationShortcut(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")
        chord.configure { $0.shortcut = shortcut }
        precondition(chord.decideForTesting(.keyDown, keyCode: 49, modifiers: shortcut.modifiers, at: 1) ==
            .init(consume: true, actions: [.typed, .start]))
        precondition(chord.decideForTesting(.keyDown, keyCode: 49, modifiers: shortcut.modifiers,
            repeating: true, at: 1.1).consume)
        precondition(chord.decideForTesting(.keyUp, keyCode: 49, modifiers: shortcut.modifiers, at: 1.5) ==
            .init(consume: true, actions: [.stop(1.5)]))

        let disabled = ShortcutEventTap()
        disabled.configure { $0.dictationEnabled = false }
        precondition(disabled.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 1) ==
            .init(consume: false, actions: []))
        precondition(disabled.decideForTesting(.flagsChanged, keyCode: 63, modifiers: [], at: 1.1) ==
            .init(consume: false, actions: []))

        let ticket = ShortcutTargetTicket(generation: 7, pid: 123)
        precondition(ticket.accepts(generation: 7, frontmostPID: 123))
        precondition(!ticket.accepts(generation: 8, frontmostPID: 123), "Cancelled press must reject its late AX result")
        precondition(!ticket.accepts(generation: 7, frontmostPID: 456), "Focus moved to another app")
        print("PASS: shortcut tap ordering, Fn pass-through, chord consumption, disabled state and stale target gates.")
    }
}
