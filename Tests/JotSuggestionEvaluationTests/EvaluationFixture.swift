import XCTest
@testable import JotSuggestionEvaluation

enum EvaluationFixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let corpusURL = root.appendingPathComponent("docs/evaluation/contextual-suggestions/scenarios.json")

    /// Every record key, matching scripts/check-suggestion-results.py.
    static let recordKeys: Set<String> = [
        "format", "version", "runId", "iteration", "mode", "scenarioId", "generator", "run", "selectedSources",
        "excludedSources", "outcome", "detail", "rawOutput", "outputText", "change", "timeToPreviewMs", "generationMs",
        "durationMs", "promptSHA256", "selectionComparison", "outcomeComparison", "scores", "scorer", "notes",
    ]

    /// Test data only: a deterministic stand-in derived from the prompt, never presented as model output.
    static let fakeGenerator: ModelCallGate.Generator = { request in "TEST DATA " + String(request.sha256.prefix(12)) }

    static func corpusData() throws -> Data { try Data(contentsOf: corpusURL) }
    static func corpus() throws -> Corpus { try Corpus.decode(corpusData()) }
    static func corpusJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: corpusData()) as? [String: Any])
    }
    static func scenario(_ id: String) throws -> CorpusScenario {
        try XCTUnwrap(corpus().scenarios.first { $0.id == id })
    }

    static func target(mode: SuggestionMode = .reply, project: String? = "alpha", conversation: String? = "chat-1") -> Target {
        Target(app: "Test chat", mode: mode, purpose: "chat-reply", project: project, conversation: conversation, cwd: nil,
               inputRevision: 0, before: "", after: "", requestedAt: "2026-09-20T12:00:00Z")
    }

    static func source(_ id: String, kind: String = "dictation", role: String = "user", speaker: String? = nil,
                       project: String? = "alpha", conversation: String? = nil,
                       timestamp: String = "2026-09-20T10:00:00Z", revision: Int = 1,
                       status: Source.Status = .current, text: String? = nil, derivedFrom: [SourceRevision]? = nil,
                       duplicateOf: String? = nil) -> Source {
        Source(id: id, kind: kind, role: role, speaker: speaker, origin: "test",
               scope: Source.Scope(project: project, conversation: conversation, session: nil), timestamp: timestamp,
               revision: revision, status: status, text: text ?? "Test source \(id).", derivedFrom: derivedFrom,
               duplicateOf: duplicateOf)
    }

    static func syntheticScenario(sources: [Source]) -> CorpusScenario {
        CorpusScenario(id: "test-scenario", target: EvaluationFixture.target(), sources: sources, pendingSuggestion: nil,
                       change: nil, expected: Expected(outcome: "abstain", includedSources: [], excludedSources: []),
                       scoring: Scoring(criteria: ["outcome"]))
    }

    @MainActor
    static func records(_ corpus: Corpus, mode: EvaluationMode = .normal, iterations: Int = 1,
                        generator: @escaping ModelCallGate.Generator = EvaluationFixture.fakeGenerator) async throws
        -> [EvaluationRecord] {
        let configuration = EvaluationConfiguration(mode: mode, iterations: iterations, generatorLabel: "test-fake")
        let evaluation = SuggestionEvaluation(configuration: configuration, generator: generator)
        var records: [EvaluationRecord] = []
        try await evaluation.run(corpus) { records.append($0) }
        return records
    }
}

/// The parts of a record that must depend only on the scenario input and the generator.
struct ObservedRecord: Equatable {
    let scenarioID: String
    let selected: [SourceRevision]
    let excluded: [SourceSelection.Exclusion]
    let run: String?
    let outcome: Outcome
    let detail: String?
    let rawOutput: String?
    let outputText: String?
    let promptSHA256: String?
    let change: ChangeResult?
}

extension EvaluationRecord {
    var observed: ObservedRecord {
        ObservedRecord(scenarioID: scenarioID, selected: selection.references, excluded: selection.excluded, run: run,
                       outcome: outcome, detail: detail, rawOutput: rawOutput, outputText: outputText,
                       promptSHA256: request?.sha256, change: change)
    }
}

/// Records generator calls from any concurrency domain.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func generator(_ wrapped: @escaping ModelCallGate.Generator) -> ModelCallGate.Generator {
        { request in
            self.increment()
            return try await wrapped(request)
        }
    }

    private func increment() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

/// A generator stand-in that ignores cancellation until the test releases it.
actor ReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
