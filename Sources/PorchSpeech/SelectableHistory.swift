import AppKit
import SwiftUI
import PorchCore

/// One text document permits native selection across statement boundaries.
struct SelectableHistory: NSViewRepresentable {
    let transcripts: [Transcript]
    let search: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 12)
        text.delegate = context.coordinator
        text.setAccessibilityLabel("Selectable transcript history")
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        context.coordinator.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let output = NSMutableAttributedString()
        for item in transcripts.reversed() {
            let speaker = item.speakerLabel ?? item.speakerID ?? (item.mode == "dictation" ? "Dictation" : "Unknown speaker")
            let timestamp = item.startedAt.addingTimeInterval(item.startSeconds).formatted(date: .abbreviated, time: .shortened)
            output.append(NSAttributedString(string: "\(speaker) · \(timestamp)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
            ]))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 12
            output.append(NSAttributedString(string: item.text + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ]))
        }
        context.coordinator.receive(output, search: search)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private var pending: NSAttributedString?
        private var search: String?
        private var applying = false

        func receive(_ document: NSAttributedString, search query: String) {
            guard let textView else { return }
            let changedSearch = search != query
            search = query
            pending = document
            // A new query deliberately replaces the old results. Ambient updates wait
            // until the selection is cleared, keeping Copy tied to what was highlighted.
            if changedSearch || textView.selectedRange().length == 0 { applyPending(reset: changedSearch) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, textView?.selectedRange().length == 0 else { return }
            applyPending(reset: false)
        }

        private func applyPending(reset: Bool) {
            guard let textView, let pending, let storage = textView.textStorage else { return }
            self.pending = nil
            guard !storage.isEqual(to: pending) else { return }
            let scroll = textView.enclosingScrollView
            let origin = scroll?.contentView.bounds.origin ?? .zero
            let atBottom = (scroll?.contentView.bounds.maxY ?? 0) >= textView.bounds.height - 2
            applying = true
            storage.setAttributedString(pending)
            textView.setSelectedRange(NSRange(location: min(textView.selectedRange().location, storage.length), length: 0))
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            if reset || atBottom { textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
            else { scroll?.contentView.scroll(to: origin); if let scroll { scroll.reflectScrolledClipView(scroll.contentView) } }
            applying = false
        }
    }
}
