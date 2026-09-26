import Foundation

enum EvaluationMode: String, CaseIterable {
    case normal
    /// Generates from exactly the corpus's expected sources, isolating the model from retrieval.
    case oracleContext = "oracle-context"
}

enum Outcome: String {
    case suggest, abstain, invalidate, rejected, unavailable, error, timeout
}

struct EvaluationConfiguration {
    var mode: EvaluationMode = .normal
    var iterations = 1
    var runID = UUID().uuidString.lowercased()
    /// `apple-fm` for the executable; `test-fake` marks records made by an injected test generator.
    var generatorLabel: String
    var limits = SelectionLimits.experiment
    var deadline: Duration = .seconds(2)
    var cancellationGrace: Duration = .seconds(2)
}

struct ChangeResult: Equatable {
    let kind: String
    /// nil when no preview was generated to withdraw.
    let generatedPreviewWithdrawn: Bool?
    /// The corpus's authored preview, checked deterministically whatever the model returned.
    let authoredPreviewWithdrawn: Bool?
}

/// Deterministic retrieval evidence, kept apart from the human quality scores.
struct SelectionComparison: Equatable {
    struct Mismatch: Equatable {
        let id: String
        let expected: String
        let actual: String
    }
    let missing: [String]
    let unexpected: [String]
    let reasonMismatches: [Mismatch]
    var matches: Bool { missing.isEmpty && unexpected.isEmpty && reasonMismatches.isEmpty }

    init(expected: Expected, selection: SourceSelection) {
        let selected = selection.selected.map(\.id)
        missing = expected.includedSources.filter { !selected.contains($0) }
        unexpected = selected.filter { !expected.includedSources.contains($0) }
        reasonMismatches = expected.excludedSources.compactMap { exclusion in
            guard let actual = selection.excluded.first(where: { $0.id == exclusion.id }),
                  actual.reason.rawValue != exclusion.reason else { return nil }
            return Mismatch(id: exclusion.id, expected: exclusion.reason, actual: actual.reason.rawValue)
        }
    }
}

struct EvaluationRecord {
    let runID: String
    let iteration: Int
    let mode: EvaluationMode
    let scenarioID: String
    let generator: String
    let selection: SourceSelection
    /// `cold` for the first request this process sent to the model, `warm` after; nil when none was sent.
    var run: String?
    var outcome = Outcome.abstain
    var detail: String?
    /// The generator's response exactly as returned, before presentation processing.
    var rawOutput: String?
    var outputText: String?
    var change: ChangeResult?
    var timeToPreviewMs: Int?
    var generationMs: Int?
    var durationMs = 0
    var request: ModelRequest?
    var selectionComparison: SelectionComparison?
    var expectedOutcome = ""
    var criteria: [String] = []

    init(scenarioID: String, iteration: Int, configuration: EvaluationConfiguration, selection: SourceSelection) {
        runID = configuration.runID
        mode = configuration.mode
        generator = configuration.generatorLabel
        self.scenarioID = scenarioID
        self.iteration = iteration
        self.selection = selection
    }

    /// Every key is always present; absent values are JSON null.
    var json: [String: Any] {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        var scores: [String: Any] = [:]
        for criterion in criteria { scores[criterion] = NSNull() }
        var object: [String: Any] = [
            "format": "jot.suggestion-evaluation-record", "version": 1, "runId": runID, "iteration": iteration,
            "mode": mode.rawValue, "scenarioId": scenarioID, "generator": generator, "outcome": outcome.rawValue,
            "durationMs": durationMs, "scores": scores, "scorer": NSNull(), "notes": NSNull(),
        ]
        object["run"] = nullable(run)
        object["detail"] = nullable(detail)
        object["rawOutput"] = nullable(rawOutput)
        object["outputText"] = nullable(outputText)
        object["timeToPreviewMs"] = nullable(timeToPreviewMs)
        object["generationMs"] = nullable(generationMs)
        object["promptSHA256"] = nullable(request?.sha256)
        let selected: [[String: Any]] = selection.references.map { ["id": $0.id, "revision": $0.revision] }
        let excluded: [[String: String]] = selection.excluded.map { ["id": $0.id, "reason": $0.reason.rawValue] }
        object["selectedSources"] = selected
        object["excludedSources"] = excluded
        var changeObject: Any = NSNull()
        if let change {
            changeObject = ["kind": change.kind, "generatedPreviewWithdrawn": nullable(change.generatedPreviewWithdrawn),
                            "authoredPreviewWithdrawn": nullable(change.authoredPreviewWithdrawn)] as [String: Any]
        }
        object["change"] = changeObject
        var comparisonObject: Any = NSNull()
        if let comparison = selectionComparison {
            let mismatches: [[String: String]] = comparison.reasonMismatches.map {
                ["id": $0.id, "expected": $0.expected, "actual": $0.actual]
            }
            comparisonObject = ["matchesExpected": comparison.matches, "missingSources": comparison.missing,
                                "unexpectedSources": comparison.unexpected, "reasonMismatches": mismatches] as [String: Any]
        }
        object["selectionComparison"] = comparisonObject
        let matches = expectedOutcome == outcome.rawValue
        object["outcomeComparison"] = ["expected": expectedOutcome, "matches": matches] as [String: Any]
        return object
    }
}

func milliseconds(_ duration: Duration) -> Int { Int((duration / Duration.milliseconds(1)).rounded()) }

/// Runs every scenario in corpus order, once per iteration, with one outstanding model request.
@MainActor
final class SuggestionEvaluation {
    let configuration: EvaluationConfiguration
    let gate: ModelCallGate
    private let generator: ModelCallGate.Generator
    private var coldCallMade = false
    /// Set when a request cannot be shown to have finished; nothing further is started.
    private(set) var stopReason: String?

    init(configuration: EvaluationConfiguration, generator: @escaping ModelCallGate.Generator) {
        self.configuration = configuration
        self.generator = generator
        gate = ModelCallGate(deadline: configuration.deadline)
    }

    func run(_ corpus: Corpus, emit: (EvaluationRecord) throws -> Void) async throws {
        for iteration in 1...max(1, configuration.iterations) {
            for scenario in corpus.scenarios {
                let record = await evaluate(scenario, iteration: iteration)
                try emit(record)
                if stopReason != nil { return }
            }
        }
    }

    func evaluate(_ scenario: CorpusScenario, iteration: Int) async -> EvaluationRecord {
        let began = ContinuousClock.now
        let input = scenario.input
        let selection: SourceSelection
        switch configuration.mode {
        case .normal:
            selection = SourceSelector.select(input, limits: configuration.limits)
        case .oracleContext:
            selection = SourceSelector.oracleContext(input, included: scenario.oracle.expected.includedSources,
                                                     limits: configuration.limits)
        }
        var record = EvaluationRecord(scenarioID: scenario.id, iteration: iteration, configuration: configuration,
                                      selection: selection)
        if selection.selected.isEmpty {
            record.detail = "no-selected-source"
        } else {
            await generate(SuggestionPrompt.request(for: input, sources: selection.selected), mode: input.target.mode,
                           began: began, into: &record)
        }
        if let change = scenario.change {
            let result = changeResult(change, scenario: scenario, record: record)
            record.change = result
            if result.generatedPreviewWithdrawn == true { record.outcome = .invalidate }
        }
        // Outside oracle-context mode, the oracle is read only here, after the outcome is final.
        let oracle = scenario.oracle
        record.expectedOutcome = oracle.expected.outcome
        record.criteria = oracle.scoring.criteria
        if configuration.mode == .normal {
            record.selectionComparison = SelectionComparison(expected: oracle.expected, selection: selection)
        }
        record.durationMs = milliseconds(began.duration(to: .now))
        return record
    }

    private func generate(_ request: ModelRequest, mode: SuggestionMode, began: ContinuousClock.Instant,
                          into record: inout EvaluationRecord) async {
        record.request = request
        let callBegan = ContinuousClock.now
        let result = await gate.call(request, generator: generator)
        record.generationMs = milliseconds(callBegan.duration(to: .now))
        switch result {
        case .unavailable, .blocked: break
        default:
            record.run = coldCallMade ? "warm" : "cold"
            coldCallMade = true
        }
        switch result {
        case .output(let raw):
            record.rawOutput = raw
            switch SuggestionOutput.process(raw, mode: mode) {
            case .suggestion(let text):
                record.outcome = .suggest
                record.outputText = text
                record.timeToPreviewMs = milliseconds(began.duration(to: .now))
            case .abstained(let detail):
                record.detail = detail
            case .rejected(let detail):
                record.outcome = .rejected
                record.detail = detail
            }
        case .unavailable(let reason):
            record.outcome = .unavailable
            record.detail = reason
        case .failed:
            record.outcome = .error
            record.detail = "generation-failed"
        case .timedOut:
            record.outcome = .timeout
            if await gate.settle(within: configuration.cancellationGrace) {
                record.detail = "cancelled-request-returned"
            } else {
                record.detail = "cancelled-request-still-running"
                stopReason = "A timed-out model request had not returned after the cancellation grace period, so no further request was started."
            }
        case .blocked:
            record.outcome = .error
            record.detail = "earlier-request-still-running"
            stopReason = "An earlier model request was still running, so no overlapping request was started."
        }
    }

    /// Simulates the change after the preview appears. Acceptance would reread the target and sources.
    private func changeResult(_ change: Change, scenario: CorpusScenario, record: EvaluationRecord) -> ChangeResult {
        let input = scenario.input
        let changed = change.applied(to: input)
        let generated: Bool? = record.outcome == .suggest
            ? !Preview(for: input, sources: record.selection.references).isCurrent(for: changed) : nil
        let authored: Bool? = scenario.pendingSuggestion.map { pending in
            var shown = input
            shown.target.inputRevision = pending.inputRevision
            let references = input.sources.filter { pending.sourceIds.contains($0.id) }
                .map { SourceRevision(id: $0.id, revision: $0.revision) }
            return !Preview(for: shown, sources: references).isCurrent(for: changed)
        }
        return ChangeResult(kind: change.kind, generatedPreviewWithdrawn: generated, authoredPreviewWithdrawn: authored)
    }
}

struct RuntimeInfo {
    var operatingSystem: String
    var hardwareModel: String?
    var modelAvailability: String
}

struct RunMetadata {
    let configuration: EvaluationConfiguration
    let corpus: Corpus
    let corpusPath: String
    let corpusSHA256: String
    let sourceRevision: String?
    let runtime: RuntimeInfo
    let startedAt: Date
    var finishedAt: Date?
    var stopReason: String?
    var recordCount = 0

    var json: [String: Any] {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        let formatter = ISO8601DateFormatter()
        var instructions: [String: Any] = [:]
        for mode in SuggestionMode.allCases {
            instructions[mode.rawValue] = ContentHash.sha256(SuggestionPrompt.instructions(for: mode))
        }
        var object: [String: Any] = [
            "format": "jot.suggestion-evaluation-run", "version": 1, "runId": configuration.runID,
            "mode": configuration.mode.rawValue, "generator": configuration.generatorLabel,
            "iterations": configuration.iterations, "recordCount": recordCount,
            "startedAt": formatter.string(from: startedAt),
            "notice": "Synthetic corpus only. Scores stay null until a person reviews the outputs. Cold marks the first request this process sent; the system may already have had the model loaded. Apple does not expose a model revision.",
        ]
        object["finishedAt"] = nullable(finishedAt.map { formatter.string(from: $0) })
        object["completed"] = finishedAt != nil && stopReason == nil
        object["stopReason"] = nullable(stopReason)
        object["sourceRevision"] = nullable(sourceRevision)
        object["corpus"] = ["path": corpusPath, "sha256": corpusSHA256, "format": corpus.format,
                            "version": corpus.version, "scenarioCount": corpus.scenarios.count] as [String: Any]
        object["runtime"] = ["operatingSystem": runtime.operatingSystem, "hardwareModel": nullable(runtime.hardwareModel),
                             "modelAvailability": runtime.modelAvailability, "model": "SystemLanguageModel.default",
                             "modelRevision": NSNull(), "appleFMRevision": AppleFMGeneration.revision] as [String: Any]
        object["selection"] = ["maximumSources": configuration.limits.maximumSources,
                               "maximumSourceBytes": configuration.limits.maximumSourceBytes]
        object["generation"] = ["sampling": AppleFMGeneration.sampling,
                                "maximumResponseTokens": SuggestionPrompt.maximumResponseTokens,
                                "deadlineMs": milliseconds(configuration.deadline),
                                "cancellationGraceMs": milliseconds(configuration.cancellationGrace),
                                "outstandingRequests": 1, "freshSessionPerRequest": true] as [String: Any]
        object["prompt"] = ["templateID": SuggestionPrompt.templateID, "abstainMarker": SuggestionPrompt.abstainMarker,
                            "instructionsSHA256": instructions] as [String: Any]
        return object
    }
}

/// Writes one run into a directory that did not exist before, so two runs can never mix records.
final class EvaluationOutput {
    let directory: URL
    private let results: FileHandle
    private let prompts: FileHandle
    private var promptHashes: Set<String> = []

    init(creating directory: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else {
            throw EvaluationError.output("\(directory.path) already exists; choose a new output directory")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resultsURL = directory.appendingPathComponent("results.jsonl")
        let promptsURL = directory.appendingPathComponent("prompts.jsonl")
        guard manager.createFile(atPath: resultsURL.path, contents: nil),
              manager.createFile(atPath: promptsURL.path, contents: nil) else {
            throw EvaluationError.output("could not create result files in \(directory.path)")
        }
        self.directory = directory
        results = try FileHandle(forWritingTo: resultsURL)
        prompts = try FileHandle(forWritingTo: promptsURL)
    }

    deinit {
        try? results.close()
        try? prompts.close()
    }

    func writeRun(_ metadata: RunMetadata) throws {
        let data = try JSONSerialization.data(withJSONObject: metadata.json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: directory.appendingPathComponent("run.json"), options: .atomic)
    }

    /// Prompts are written once per distinct hash so a reviewer can check exactly what the model saw.
    func append(_ record: EvaluationRecord) throws {
        try results.write(contentsOf: Self.line(record.json))
        if let request = record.request, promptHashes.insert(request.sha256).inserted {
            try prompts.write(contentsOf: Self.line([
                "promptSHA256": request.sha256,
                "templateID": SuggestionPrompt.templateID,
                "scenarioId": record.scenarioID,
                "mode": record.mode.rawValue,
                "instructions": request.instructions,
                "prompt": request.prompt,
                "maximumResponseTokens": request.maximumResponseTokens,
            ]))
        }
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
