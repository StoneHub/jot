import AppKit
import QuartzCore
import SwiftUI

/// Native selectable text that marks a cleanup replacement with an accent wash
/// behind the line plus a snapshot crossfade, so a small wording change is still
/// visible from the corner of the eye. Appends remain immediate and unmarked;
/// selection keeps its original text until released.
struct LiveTranscriptText: NSViewRepresentable {
    let text: String
    let cleanupRevision: Int
    let selectionChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.font = .systemFont(ofSize: 13); view.textColor = .labelColor
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.setAccessibilityLabel("Live transcript")
        view.delegate = context.coordinator
        context.coordinator.textView = view
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.selectionChanged = selectionChanged
        context.coordinator.receive(text, revision: cleanupRevision, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        if view.selectedRange().length > 0 {
            let notify = coordinator.selectionChanged
            DispatchQueue.main.async { notify?(false) }
        }
        view.delegate = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = view.textContainer,
              let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(17, ceil(layout.usedRect(for: container).height)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var selectionChanged: ((Bool) -> Void)?
        private var revision: Int?
        private var pending: (String, Int, Bool)?
        private var applying = false
        private(set) var transitionCount = 0
        private(set) var highlightCount = 0

        func receive(_ text: String, revision: Int, reduceMotion: Bool) {
            pending = (text, revision, reduceMotion)
            if textView?.selectedRange().length == 0 { applyPending() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying else { return }
            let selected = (textView?.selectedRange().length ?? 0) > 0
            selectionChanged?(selected)
            if !selected { applyPending() }
        }

        private func applyPending() {
            guard let view = textView, let (text, nextRevision, reduceMotion) = pending else { return }
            pending = nil
            let animate = revision != nil && revision != nextRevision && !view.string.isEmpty && !reduceMotion
            revision = nextRevision
            guard view.string != text else { return }
            if animate {
                let transition = CATransition()
                transition.type = .fade; transition.duration = 0.28
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.layer?.add(transition, forKey: "phrase-cleanup")
                transitionCount += 1
                // The wording often barely changes, so the crossfade alone reads as a
                // flicker. An accent wash that lingers past it catches peripheral vision.
                if let layer = view.layer {
                    let wash = CABasicAnimation(keyPath: "backgroundColor")
                    wash.fromValue = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
                    wash.toValue = NSColor.clear.cgColor
                    wash.duration = 1.1
                    wash.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(wash, forKey: "phrase-cleanup-wash")
                    highlightCount += 1
                }
            }
            applying = true
            let caret = min(view.selectedRange().location, (text as NSString).length)
            view.string = text
            view.setSelectedRange(NSRange(location: caret, length: 0))
            view.invalidateIntrinsicContentSize()
            applying = false
        }
    }
}
