import AppKit

@main struct LiveTextChecks {
    @MainActor static func main() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        view.wantsLayer = true
        let coordinator = LiveTranscriptText.Coordinator()
        coordinator.textView = view; view.delegate = coordinator
        coordinator.receive("I think uh", revision: 0, reduceMotion: false)
        coordinator.receive("I think uh we could get faster output.", revision: 0, reduceMotion: false)
        precondition(coordinator.transitionCount == 0, "Raw appends must not animate")
        view.setSelectedRange(NSRange(location: 2, length: 8))
        let selection = view.selectedRange()
        coordinator.receive("I think we could get faster output.", revision: 1, reduceMotion: false)
        precondition(view.string.contains(" uh ") && view.selectedRange() == selection, "Cleanup overwrote selected text")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        precondition(view.string == "I think we could get faster output." && coordinator.transitionCount == 1,
            "Selection release did not apply and animate cleanup")
        coordinator.receive("We could get faster output.", revision: 2, reduceMotion: true)
        precondition(coordinator.transitionCount == 1 && view.string == "We could get faster output.", "Reduce Motion was ignored")
        print("PASS: raw append is immediate; selection survives; cleanup crossfades after release; Reduce Motion skips animation.")
    }
}
