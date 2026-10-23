@testable import JotCore

// Shorthands the app never calls. Each builds on the API the app does use, so tests exercise the live path.

extension TranscriptCleanup {
    func clean(_ texts: [String], timeout: Duration = .seconds(2), generator: Generator? = nil) async -> [String] {
        await cleanWithOutcome(texts, timeout: timeout, generator: generator).texts
    }
}

extension HeardSpeech {
    static func adding(_ match: Match?, to selected: [SuggestionSource],
                       members: (SuggestionSource) -> [Transcript] = { _ in [] }, limits: SelectionLimits = .window) -> [SuggestionSource] {
        addition(match, to: selected, members: members, limits: limits).selected
    }
}

extension SuggestionContext {
    /// The request SuggestionCoordinator builds for a field, from this context's sources.
    func input(target: SuggestionTarget, association: ContextAssociation = .explicitRecentRequest) -> SuggestionRequest {
        var input = SuggestionRequest(target: target, sources: sources)
        input.association = association
        return input
    }
}
