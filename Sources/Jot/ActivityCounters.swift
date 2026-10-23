import SwiftUI
import JotCore

/// The usage counters for the selected period: how holds ended, how text reached the field, and how often saved
/// dictation, suggestions and Fix typos were used. Counts are kept as events happen, so deleting history leaves them.
struct ActivityCounters: View {
    let counters: [String: Int]
    let reset: @MainActor () async -> Void
    @State private var confirmingReset = false
    @State private var resetting = false

    private func total(_ prefix: String) -> Int {
        counters.reduce(0) { $0 + ($1.key.hasPrefix(prefix) ? $1.value : 0) }
    }
    private func count(_ counter: UsageCounter) -> Int { counters[counter.name] ?? 0 }

    var body: some View {
        let holds = total("dictation.")
        let inserted = count(.insertion(.accessibility)) + count(.insertion(.unicode)) + count(.insertion(.clipboard))
        let notInserted = count(.insertion(.unverified)) + count(.insertion(.failed))
        let cleaned = total("cleanup.dictation.")
        let accepted = count(.suggestionAction(.acceptedVerified)) + count(.suggestionAction(.acceptedUnverified))
        JotCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("How dictation went", systemImage: "chart.bar.doc.horizontal").font(.headline)
                    Spacer(minLength: 8)
                    Button(resetting ? "Resetting…" : "Reset counters") { confirmingReset = true }
                        .buttonStyle(.borderless).font(.caption).disabled(resetting)
                        .accessibilityIdentifier("activity-reset-counters")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ActivityStat(title: "Holds", value: holds.formatted(), symbol: "hand.raised")
                    ActivityStat(title: "Inserted", value: inserted.formatted(), symbol: "checkmark.rectangle",
                                 detail: "Verified insertions: \(count(.insertion(.accessibility))) through Accessibility, \(count(.insertion(.unicode))) typed, \(count(.insertion(.clipboard))) pasted.")
                    ActivityStat(title: "Not inserted", value: notInserted.formatted(), symbol: "exclamationmark.triangle",
                                 detail: "Text Jot sent but could not verify, or could not send. Review saved dictation keeps it.")
                    ActivityStat(title: "Cleaned up", value: cleaned > 0 ? "\(count(.dictationCleanup(.changed))) of \(cleaned)" : "—", symbol: "wand.and.stars")
                    ActivityStat(title: "Saved reviews", value: count(.savedDictationReviewed).formatted(), symbol: "tray.full")
                    ActivityStat(title: "Suggestions taken", value: "\(accepted) of \(count(.suggestionRequested))", symbol: "text.badge.plus")
                    ActivityStat(title: "Typo fixes", value: "\(count(.typoFix(.fixed))) of \(count(.typoFixRequested))", symbol: "character.cursor.ibeam",
                                 detail: "Presses of the Fix typos shortcut that changed the field. \(count(.typoFix(.undone))) undone.")
                }
                Text("Counted on this Mac as you use Jot, with no text. Deleting history leaves these counts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("activity-counters")
        .confirmationDialog("Reset usage counters?", isPresented: $confirmingReset) {
            Button("Reset Counters", role: .destructive) {
                resetting = true
                Task { await reset(); resetting = false }
            }
        } message: {
            Text("Every count starts over at zero. Saved dictations and sessions stay.")
        }
    }
}
