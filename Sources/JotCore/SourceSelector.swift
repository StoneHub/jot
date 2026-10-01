import Foundation

/// Deterministic retrieval over one request's sources: explicit pins and scope, role and provenance,
/// current revisions, duplicates and the size bounds. When the bounds force a choice, the field's own
/// context, the user's own words and the sources that share the field's terms come before the rest;
/// time never makes a source relevant and only breaks ties. Whole sources are kept or excluded, never
/// truncated, so a negation or prerequisite cannot be cut off.
public enum SourceSelector {
    public static func select(_ input: SuggestionRequest, limits: SelectionLimits = .experiment) -> SourceSelection {
        var reasons: [String: ExclusionReason] = [:]
        var candidates: [SuggestionSource] = []
        for source in input.sources {
            if let reason = ineligibility(of: source, among: input.sources, for: input.target, association: input.association) {
                reasons[source.id] = reason
            } else {
                candidates.append(source)
            }
        }
        return bounded(candidates, reasons: reasons, input: input, limits: limits)
    }

    /// Oracle-context mode: exactly the authored included sources, to isolate generation from retrieval.
    public static func oracleContext(_ input: SuggestionRequest, included: [String], limits: SelectionLimits = .experiment) -> SourceSelection {
        var reasons: [String: ExclusionReason] = [:]
        for source in input.sources where !included.contains(source.id) { reasons[source.id] = .notInOracleContext }
        return bounded(input.sources.filter { included.contains($0.id) }, reasons: reasons, input: input, limits: limits)
    }

    public static func ineligibility(of source: SuggestionSource, among sources: [SuggestionSource], for target: SuggestionTarget, association: ContextAssociation = .scoped) -> ExclusionReason? {
        switch source.status {
        case .deleted: return .deleted
        case .stale: return .stale
        case .current: break
        }
        let outdated = source.derivedFrom?.contains { reference in
            guard let parent = sources.first(where: { $0.id == reference.id }) else { return false }
            return parent.status == .deleted || parent.revision > reference.revision
        } ?? false
        if outdated { return .stale }
        if source.kind == "shown-suggestion" { return .generatedNotIntent }
        if source.duplicateOf != nil { return .duplicate }
        if association == .explicitRecentRequest { return nil }
        return Self.association(of: source, with: target)
    }

    /// nil when the source belongs to the target's context. A user pin is explicit association; otherwise
    /// a known project or conversation must match, and a conflicting one excludes the source.
    public static func association(of source: SuggestionSource, with target: SuggestionTarget) -> ExclusionReason? {
        if source.kind == "pinned-selection" { return nil }
        if let project = source.scope.project, let current = target.project, project != current { return .unrelatedScope }
        if let conversation = source.scope.conversation, let current = target.conversation, conversation != current {
            return .otherConversation
        }
        let sharesProject = source.scope.project != nil && source.scope.project == target.project
        let sharesConversation = source.scope.conversation != nil && source.scope.conversation == target.conversation
        return sharesProject || sharesConversation ? nil : .unknownScope
    }

    /// Pins, then the field's own context (the text visible above it and the conversation it belongs to), then the rest.
    /// Within a tier the user's own words come first, then the sources that share the most distinctive words and
    /// three-word runs with the field's text, notes and own context; newer wins a tie. So a video playing after the
    /// user's spoken reply, or a phone call after a dictated note, fills what room is left rather than taking theirs.
    private static func bounded(_ candidates: [SuggestionSource], reasons: [String: ExclusionReason], input: SuggestionRequest,
                                limits: SelectionLimits) -> SourceSelection {
        func ownContext(_ source: SuggestionSource) -> Bool {
            source.kind == ScreenContext.kind
                || (source.scope.conversation != nil && source.scope.conversation == input.target.conversation)
        }
        let query = HeardSpeech.Terms(([input.target.before, input.target.after, input.target.seed ?? ""]
            + input.sources.filter(ownContext).map(\.text)).joined(separator: " "))
        struct Ranked { let offset: Int; let source: SuggestionSource; let tier: Int; let own: Bool; let relevance: Int }
        let ranked = candidates.enumerated().map { offset, source -> Ranked in
            // One shared word is noise ("until", "tonight"); two, or a shared run, says the source is about the same thing.
            let shared = HeardSpeech.Terms(source.text).shared(with: query)
            let relevance = shared.words >= 2 || shared.runs > 0 ? shared.words + 2 * shared.runs : 0
            return Ranked(offset: offset, source: source,
                          tier: source.kind == "pinned-selection" ? 0 : ownContext(source) ? 1 : 2,
                          own: source.role == "user", relevance: relevance)
        }.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.own != b.own { return a.own }
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            if a.source.timestamp != b.source.timestamp { return a.source.timestamp > b.source.timestamp }
            return a.offset < b.offset
        }.map(\.source)
        var reasons = reasons
        var kept: Set<String> = []
        var bytes = 0
        for source in ranked {
            let size = source.text.utf8.count
            if kept.count < limits.maximumSources, bytes + size <= limits.maximumSourceBytes {
                kept.insert(source.id)
                bytes += size
            } else {
                reasons[source.id] = .overLimit
            }
        }
        let selected = input.sources.enumerated().filter { kept.contains($0.element.id) }.sorted { first, second in
            first.element.timestamp != second.element.timestamp
                ? first.element.timestamp < second.element.timestamp : first.offset < second.offset
        }.map(\.element)
        let excluded = input.sources.compactMap { source in
            reasons[source.id].map { SourceSelection.Exclusion(id: source.id, reason: $0) }
        }
        return SourceSelection(selected: selected, excluded: excluded)
    }
}
