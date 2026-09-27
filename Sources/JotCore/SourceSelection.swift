import Foundation

public enum ExclusionReason: String, Sendable {
    case deleted, stale, duplicate
    case generatedNotIntent = "generated-not-intent"
    case unrelatedScope = "unrelated-scope"
    case otherConversation = "other-conversation"
    case unknownScope = "unknown-scope"
    case overLimit = "over-limit"
    case notInOracleContext = "not-in-oracle-context"
}

/// The experiment's proposed bounds from docs/CONTEXTUAL-SUGGESTIONS.md; tunable, not architecture.
public struct SelectionLimits: Equatable, Sendable {
    public init(maximumSources: Int = 6, maximumSourceBytes: Int = 4096) {
        self.maximumSources = maximumSources; self.maximumSourceBytes = maximumSourceBytes
    }
    public var maximumSources = 6
    public var maximumSourceBytes = 4096
    public static let experiment = SelectionLimits()
}

public struct SourceSelection: Equatable, Sendable {
    public struct Exclusion: Equatable, Sendable {
        public let id: String
        public let reason: ExclusionReason
    }
    /// Oldest first, as the prompt presents them.
    public var selected: [Source]
    /// Corpus order.
    public var excluded: [Exclusion]

    public var references: [SourceRevision] { selected.map { SourceRevision(id: $0.id, revision: $0.revision) } }
}

/// Deterministic retrieval over one scenario's sources: explicit pins and scope, role and provenance,
/// current revisions, duplicates and the size bounds. Time never makes a source relevant; it only
/// orders sources that already qualify when the bounds force a choice. Whole sources are kept or
/// excluded, never truncated, so a negation or prerequisite cannot be cut off.
public enum SourceSelector {
    public static func select(_ input: ScenarioInput, limits: SelectionLimits = .experiment) -> SourceSelection {
        var reasons: [String: ExclusionReason] = [:]
        var candidates: [Source] = []
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
    public static func oracleContext(_ input: ScenarioInput, included: [String], limits: SelectionLimits = .experiment) -> SourceSelection {
        var reasons: [String: ExclusionReason] = [:]
        for source in input.sources where !included.contains(source.id) { reasons[source.id] = .notInOracleContext }
        return bounded(input.sources.filter { included.contains($0.id) }, reasons: reasons, input: input, limits: limits)
    }

    public static func ineligibility(of source: Source, among sources: [Source], for target: Target, association: ContextAssociation = .scoped) -> ExclusionReason? {
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
    public static func association(of source: Source, with target: Target) -> ExclusionReason? {
        if source.kind == "pinned-selection" { return nil }
        if let project = source.scope.project, let current = target.project, project != current { return .unrelatedScope }
        if let conversation = source.scope.conversation, let current = target.conversation, conversation != current {
            return .otherConversation
        }
        let sharesProject = source.scope.project != nil && source.scope.project == target.project
        let sharesConversation = source.scope.conversation != nil && source.scope.conversation == target.conversation
        return sharesProject || sharesConversation ? nil : .unknownScope
    }

    /// Pins, then this conversation, then the project; newest first within a tier.
    private static func bounded(_ candidates: [Source], reasons: [String: ExclusionReason], input: ScenarioInput,
                                limits: SelectionLimits) -> SourceSelection {
        func tier(_ source: Source) -> Int {
            if source.kind == "pinned-selection" { return 0 }
            if source.scope.conversation != nil && source.scope.conversation == input.target.conversation { return 1 }
            return 2
        }
        let ranked = candidates.enumerated().sorted { first, second in
            let (a, b) = (first.element, second.element)
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return first.offset < second.offset
        }.map(\.element)
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
