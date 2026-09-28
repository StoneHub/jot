import AppKit
import SwiftUI
import JotCore

/// An explicit snapshot of an undelivered hold. Copying never claims that another app received it.
struct SavedDictationReview: View {
    @ObservedObject var service: SpeechService
    @Environment(\.dismiss) private var dismiss
    @State private var attempt: DictationAttempt?
    @State private var loading = true
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved dictation").font(.title2.bold())
            if loading {
                ProgressView("Reading saved text…")
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let attempt {
                Text(attempt.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if attempt.hasGap {
                    Text("Some audio was not recognized. This is the saved portion.").foregroundStyle(.orange)
                }
                Text("Check the original field before pasting: some or all of this text may already be there.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(attempt.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: 260)
                Button(copied ? "Copied" : "Copy text") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(attempt.text, forType: .string)
                }.modifier(GlassButton()).accessibilityIdentifier("copy-saved-dictation")
                Text("Paste it where you want it. Copying keeps this saved dictation available.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No saved dictation needs recovery.")
                Text("Other captured speech stays in Sessions. Jot does not substitute room speech for a failed dictation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 420)
        .task {
            do { attempt = try await service.dictation.savedDictationForReview() }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct ReviewSavedDictationButton: View {
    @ObservedObject var service: SpeechService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Review saved dictation") {
            openWindow(id: "main")
            service.showingSavedDictation = true
        }
        .disabled(service.dictation.isActive || service.dictation.isPending)
        .accessibilityIdentifier("review-saved-dictation")
    }
}
