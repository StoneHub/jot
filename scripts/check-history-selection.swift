import AppKit

/// Run with SelectableHistory.swift and the built PorchCore framework. No window or microphone is opened.
@main
struct HistorySelectionChecks {
    static func main() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let coordinator = SelectableHistory.Coordinator()
        coordinator.textView = text
        text.delegate = coordinator
        let original = "First statement.\n\nSecond statement."
        coordinator.receive(NSAttributedString(string: original), search: "")
        text.setSelectedRange(NSRange(location: 6, length: 23))
        let selection = text.selectedRange()
        coordinator.receive(NSAttributedString(string: original + "\n\nThird statement."), search: "")
        precondition(text.string == original, "Incoming history replaced selected text")
        precondition(text.selectedRange() == selection, "Incoming history moved selection")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        precondition(text.string.hasSuffix("Third statement."), "Clearing selection did not apply pending history")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        coordinator.receive(NSAttributedString(string: "Search result."), search: "result")
        precondition(text.string == "Search result.", "A new query retained stale selected results")
        precondition(text.selectedRange().length == 0, "A new query retained stale selection")
        print("Selection checks passed: updates wait, selection is stable, clearing catches up, search resets.")
    }
}
