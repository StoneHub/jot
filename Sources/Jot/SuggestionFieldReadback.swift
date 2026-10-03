import AppKit
import ApplicationServices
import JotCore

/// What one re-read of the captured field found. `DictationInput` compares it with the `SuggestionField` a card was made from.
struct SuggestionFieldReadback: Sendable {
    let draft: SuggestionDraftSnapshot
    let role: String
    let placeholder: String?
    /// The field's rectangle in AppKit coordinates; nil when the app reports no usable one.
    let frame: CGRect?
    /// The raw AX value and the hint it turned out to be, if any, for `DictationInput`'s hint cache.
    let value: String
    let drawnHint: String?
}
