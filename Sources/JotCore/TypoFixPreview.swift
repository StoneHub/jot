import Foundation

/// The typo check that the first double-tap of Fn runs in a field with text: what its card lists, and how each check
/// ended. Outcomes are codes only; the card text never leaves the card.
public enum TypoFixPreview {
    /// How one double-Fn typo check ended. Every check the model was asked for ends in exactly one of these.
    public enum Outcome: String, Sendable, CaseIterable {
        /// Tab wrote the fix and it read back.
        case applied
        /// Tab was pressed, but the field changed, would not take the selection, or did not read back as expected.
        case notApplied
        /// The fix was shown and passed over: a second double-Fn, Escape, typing, focus moving, or 30 seconds.
        case skipped
        /// The model found no typos, so the request went on to a suggestion.
        case noTypos
        /// The model changed more than typos, so nothing was shown and the request went on to a suggestion.
        case rejected
        /// The model was unavailable, failed or took too long, so the request went on to a suggestion.
        case failed
        /// The check was still running when the user moved on or asked for a suggestion.
        case cancelled
    }

    /// The fixes in `corrected`, as `TypoFixReview` built it from `source`, one per line as "before → after" in field
    /// order. A removed or added word is shown with the word beside it, so the line says where it was. After `limit`
    /// lines, one more says how many fixes are not listed.
    public static func summary(source: String, corrected: String, limit: Int = 4) -> String {
        let from = TypoFixReview.tokens(in: source), to = TypoFixReview.tokens(in: corrected)
        guard let regions = TypoFixReview.changedRegions(from.map(\.text), to.map(\.text)) else { return "" }
        let lines = regions.map { region -> String in
            var before = region.source, after = region.output
            if before.isEmpty || after.isEmpty {
                // Both sides share the word just before the change, or just after it at the start of the text.
                if before.lowerBound > 0 && after.lowerBound > 0 {
                    before = (before.lowerBound - 1)..<before.upperBound; after = (after.lowerBound - 1)..<after.upperBound
                } else if before.upperBound < from.count && after.upperBound < to.count {
                    before = before.lowerBound..<(before.upperBound + 1); after = after.lowerBound..<(after.upperBound + 1)
                }
            }
            return shortened(from[before].map(\.text).joined(separator: " ")) + " → "
                + shortened(to[after].map(\.text).joined(separator: " "))
        }
        guard lines.count > limit else { return lines.joined(separator: "\n") }
        let rest = lines.count - limit
        return (lines.prefix(limit) + [rest == 1 ? "and 1 more" : "and \(rest) more"]).joined(separator: "\n")
    }

    private static func shortened(_ text: String) -> String {
        text.count <= 40 ? text : String(text.prefix(39)) + "…"
    }
}
