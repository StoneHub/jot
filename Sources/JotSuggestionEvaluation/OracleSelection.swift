import JotCore

/// Authored oracle sources bypass production eligibility, but share its ranking
/// and whole-source size bounds. Only the evaluation executable can make this choice.
enum OracleSelection {
    static func select(_ input: SuggestionRequest, included: [String], limits: SelectionLimits = .experiment) -> SourceSelection {
        let ids = Set(included)
        let reasons = Dictionary(uniqueKeysWithValues: input.sources.filter { !ids.contains($0.id) }.map { ($0.id, ExclusionReason.notInOracleContext) })
        return SourceSelector.bound(input.sources.filter { ids.contains($0.id) }, reasons: reasons, input: input, limits: limits)
    }
}
