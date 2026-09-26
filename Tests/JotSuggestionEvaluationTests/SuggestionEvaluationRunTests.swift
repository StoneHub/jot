import XCTest
@testable import JotSuggestionEvaluation

final class SuggestionEvaluationRunTests: XCTestCase {
    @MainActor func testFakeRunRecordsEveryScenarioAndSeparatesColdFromWarmCalls() async throws {
        let corpus = try EvaluationFixture.corpus()
        let log = CallLog()
        let records = try await EvaluationFixture.records(corpus, iterations: 2,
                                                          generator: log.generator(EvaluationFixture.fakeGenerator))
        XCTAssertEqual(records.map(\.scenarioID), corpus.scenarios.map(\.id) + corpus.scenarios.map(\.id))
        let called = records.filter { $0.request != nil }
        XCTAssertEqual(log.count, called.count)
        let expectedRuns: [String?] = ["cold"] + Array(repeating: "warm", count: called.count - 1)
        XCTAssertEqual(called.map(\.run), expectedRuns, "Only the first request of the process is cold")

        let unrelated = try XCTUnwrap(records.first { $0.scenarioID == "shell-blank-unrelated-project" })
        XCTAssertEqual(unrelated.outcome, .abstain)
        XCTAssertEqual(unrelated.detail, "no-selected-source")
        XCTAssertNil(unrelated.run, "No request was sent")
        XCTAssertNil(unrelated.request)

        for record in records {
            let json = record.json
            XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
            XCTAssertEqual(Set(json.keys), EvaluationFixture.recordKeys)
            XCTAssertEqual(json["generator"] as? String, "test-fake", "Fake responses are labeled test data")
            let scores = try XCTUnwrap(json["scores"] as? [String: Any])
            XCTAssertFalse(scores.isEmpty)
            XCTAssertTrue(scores.values.allSatisfy { $0 is NSNull }, "Quality stays unscored until reviewed")
            XCTAssertTrue(json["scorer"] is NSNull)
            if let raw = record.rawOutput { XCTAssertTrue(raw.hasPrefix("TEST DATA ")) }
        }
    }

    @MainActor func testSimulatedChangesWithdrawTheGeneratedAndAuthoredPreviews() async throws {
        let records = try await EvaluationFixture.records(EvaluationFixture.corpus())
        for id in ["agent-same-length-edit-after-preview", "shell-source-deleted-after-preview"] {
            let record = try XCTUnwrap(records.first { $0.scenarioID == id })
            XCTAssertEqual(record.outcome, .invalidate, id)
            XCTAssertEqual(record.change?.generatedPreviewWithdrawn, true, id)
            XCTAssertEqual(record.change?.authoredPreviewWithdrawn, true, id)
            XCTAssertNotNil(record.outputText, "The withdrawn preview stays in the record")
            XCTAssertNotNil(record.timeToPreviewMs)
        }
        XCTAssertTrue(records.filter { $0.change == nil }.allSatisfy { $0.outcome != .invalidate })

        let abstaining = try await EvaluationFixture.records(EvaluationFixture.corpus(), generator: { _ in "NO_SUGGESTION" })
        let edit = try XCTUnwrap(abstaining.first { $0.scenarioID == "agent-same-length-edit-after-preview" })
        XCTAssertEqual(edit.outcome, .abstain)
        XCTAssertEqual(edit.detail, "model-abstained")
        XCTAssertEqual(edit.rawOutput, "NO_SUGGESTION")
        XCTAssertNotNil(edit.change)
        XCTAssertNil(edit.change?.generatedPreviewWithdrawn, "Nothing was generated to withdraw")
        XCTAssertEqual(edit.change?.authoredPreviewWithdrawn, true, "Freshness is still checked deterministically")
    }

    @MainActor func testRawOutputIsKeptBeforePresentationProcessing() async throws {
        let scenario = try EvaluationFixture.scenario("shell-blank-matching-project")
        let evaluation = SuggestionEvaluation(configuration: EvaluationConfiguration(generatorLabel: "test-fake"),
                                              generator: { _ in "  `make test-export`\n" })
        let record = await evaluation.evaluate(scenario, iteration: 1)
        XCTAssertEqual(record.outcome, .suggest)
        XCTAssertEqual(record.rawOutput, "  `make test-export`\n")
        XCTAssertEqual(record.outputText, "make test-export")
        XCTAssertEqual(record.selectionComparison?.matches, true)
        XCTAssertEqual(record.json["outcomeComparison"] as? [String: AnyHashable], ["expected": "suggest", "matches": true])
    }

    @MainActor func testOversizedOnlySourceAbstainsBeforeInference() async {
        let log = CallLog()
        let scenario = EvaluationFixture.syntheticScenario(sources: [
            EvaluationFixture.source("big", text: String(repeating: "b", count: 5000)),
        ])
        let evaluation = SuggestionEvaluation(configuration: EvaluationConfiguration(generatorLabel: "test-fake"),
                                              generator: log.generator(EvaluationFixture.fakeGenerator))
        let record = await evaluation.evaluate(scenario, iteration: 1)
        XCTAssertEqual(record.outcome, .abstain)
        XCTAssertEqual(record.detail, "no-selected-source")
        XCTAssertEqual(record.selection.excluded, [.init(id: "big", reason: .overLimit)])
        XCTAssertNil(record.run)
        XCTAssertEqual(log.count, 0)
    }

    @MainActor func testUnavailableAndFailedModelsAreRecordedHonestly() async throws {
        let corpus = try EvaluationFixture.corpus()
        let unavailable = try await EvaluationFixture.records(corpus, generator: { _ in
            throw ModelUnavailable(reason: "model_not_ready")
        })
        for record in unavailable where record.request != nil {
            XCTAssertEqual(record.outcome, .unavailable)
            XCTAssertEqual(record.detail, "model_not_ready")
            XCTAssertNil(record.run, "An unavailable model was never asked, so no request is cold or warm")
            XCTAssertNil(record.rawOutput)
        }
        struct ModelFailure: Error {}
        let failed = try await EvaluationFixture.records(corpus, generator: { _ in throw ModelFailure() })
        for record in failed where record.request != nil {
            XCTAssertEqual(record.outcome, .error)
            XCTAssertEqual(record.detail, "generation-failed")
            XCTAssertNotNil(record.run)
        }
    }

    @MainActor func testTimedOutRequestThatHonorsCancellationLetsTheRunContinue() async throws {
        let corpus = try EvaluationFixture.corpus()
        let configuration = EvaluationConfiguration(generatorLabel: "test-fake", deadline: .milliseconds(50),
                                                    cancellationGrace: .seconds(1))
        let evaluation = SuggestionEvaluation(configuration: configuration, generator: { _ in
            try await Task.sleep(for: .seconds(10))
            return "late"
        })
        var records: [EvaluationRecord] = []
        let began = ContinuousClock.now
        try await evaluation.run(corpus) { records.append($0) }
        XCTAssertLessThan(began.duration(to: .now), .seconds(5))
        XCTAssertEqual(records.count, corpus.scenarios.count)
        XCTAssertNil(evaluation.stopReason)
        for record in records where record.request != nil {
            XCTAssertEqual(record.outcome, .timeout)
            XCTAssertEqual(record.detail, "cancelled-request-returned")
            XCTAssertNil(record.rawOutput, "A late response is never recorded as the result")
        }
    }

    @MainActor func testRequestThatIgnoresCancellationStopsTheRunWithoutOverlap() async throws {
        let log = CallLog()
        let release = ReleaseGate()
        let configuration = EvaluationConfiguration(generatorLabel: "test-fake", deadline: .milliseconds(50),
                                                    cancellationGrace: .milliseconds(100))
        let evaluation = SuggestionEvaluation(configuration: configuration, generator: log.generator { _ in
            await release.wait()
            return "late"
        })
        var records: [EvaluationRecord] = []
        try await evaluation.run(EvaluationFixture.corpus()) { records.append($0) }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .timeout)
        XCTAssertEqual(records.first?.detail, "cancelled-request-still-running")
        XCTAssertNotNil(evaluation.stopReason)
        XCTAssertTrue(evaluation.gate.outstanding)

        let request = ModelRequest(instructions: "test", prompt: "test", maximumResponseTokens: 1)
        let blocked = await evaluation.gate.call(request, generator: log.generator(EvaluationFixture.fakeGenerator))
        XCTAssertEqual(blocked, .blocked)
        XCTAssertEqual(log.count, 1, "No request overlapped the unfinished one")
        await release.release()
        let settled = await evaluation.gate.settle(within: .seconds(1))
        XCTAssertTrue(settled)
        XCTAssertFalse(evaluation.gate.outstanding)
    }

    @MainActor func testGateAllowsOneOutstandingRequest() async {
        let gate = ModelCallGate(deadline: .seconds(5))
        let release = ReleaseGate()
        let started = expectation(description: "First request started")
        let request = ModelRequest(instructions: "test", prompt: "test", maximumResponseTokens: 1)
        let first = Task {
            await gate.call(request, generator: { _ in
                started.fulfill()
                await release.wait()
                return "first"
            })
        }
        await fulfillment(of: [started], timeout: 1)
        let second = await gate.call(request, generator: { _ in
            XCTFail("A second request must not overlap the first")
            return "second"
        })
        XCTAssertEqual(second, .blocked)
        await release.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .output("first"))
        XCTAssertFalse(gate.outstanding)
    }

    @MainActor func testCommandWritesAFreshOutputDirectoryAndRefusesToReuseIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("normal")
        let options = try XCTUnwrap(CommandOptions.parse([
            "--corpus", EvaluationFixture.corpusURL.path, "--output", output.path, "--iterations", "2",
            "--source-revision", "test-revision",
        ]))
        let runtime = RuntimeInfo(operatingSystem: "test", hardwareModel: nil, modelAvailability: "test-fake")
        let status = try await SuggestionEvaluationCommand.run(options, generator: EvaluationFixture.fakeGenerator,
                                                               generatorLabel: "test-fake", runtime: runtime)
        XCTAssertEqual(status, 0)

        let run = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathComponent("run.json"))) as? [String: Any])
        let scenarioCount = try EvaluationFixture.corpus().scenarios.count
        XCTAssertEqual(run["completed"] as? Bool, true)
        XCTAssertTrue(run["stopReason"] is NSNull)
        XCTAssertEqual(run["generator"] as? String, "test-fake")
        XCTAssertEqual(run["mode"] as? String, "normal")
        XCTAssertEqual(run["sourceRevision"] as? String, "test-revision")
        XCTAssertEqual(run["recordCount"] as? Int, 2 * scenarioCount)
        let corpus = try XCTUnwrap(run["corpus"] as? [String: Any])
        XCTAssertEqual(corpus["sha256"] as? String, ContentHash.sha256(try EvaluationFixture.corpusData()))
        let runtimeObject = try XCTUnwrap(run["runtime"] as? [String: Any])
        XCTAssertTrue(runtimeObject["modelRevision"] is NSNull, "Apple does not expose a model revision")
        XCTAssertEqual(runtimeObject["appleFMRevision"] as? String, AppleFMGeneration.revision)
        let generation = try XCTUnwrap(run["generation"] as? [String: Any])
        XCTAssertEqual(generation["maximumResponseTokens"] as? Int, 128)
        XCTAssertEqual(generation["deadlineMs"] as? Int, 2000)
        XCTAssertEqual(generation["outstandingRequests"] as? Int, 1)

        func lines(_ name: String) throws -> [[String: Any]] {
            try String(contentsOf: output.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
        let results = try lines("results.jsonl")
        XCTAssertEqual(results.count, 2 * scenarioCount)
        XCTAssertTrue(results.allSatisfy { Set($0.keys) == EvaluationFixture.recordKeys })
        let runs = results.compactMap { $0["run"] as? String }
        XCTAssertEqual(runs.first, "cold")
        XCTAssertEqual(runs.filter { $0 == "cold" }.count, 1)
        let prompts = try lines("prompts.jsonl")
        XCTAssertEqual(prompts.count, runs.count / 2, "Each distinct prompt is written once")
        XCTAssertTrue(prompts.allSatisfy { ($0["prompt"] as? String)?.isEmpty == false })

        do {
            _ = try await SuggestionEvaluationCommand.run(options, generator: EvaluationFixture.fakeGenerator,
                                                          generatorLabel: "test-fake", runtime: runtime)
            XCTFail("An existing output directory must be refused")
        } catch let error as EvaluationError {
            XCTAssertTrue(error.description.contains("already exists"))
        }
        XCTAssertEqual(try lines("results.jsonl").count, 2 * scenarioCount, "The earlier run is untouched")
    }

    func testCommandOptionsRequireExplicitPathsAndKnownModes() throws {
        XCTAssertNil(try CommandOptions.parse(["--help"]))
        let options = try XCTUnwrap(CommandOptions.parse(["--corpus", "c.json", "--output", "out", "--mode", "oracle-context"]))
        XCTAssertEqual(options.mode, .oracleContext)
        XCTAssertEqual(options.iterations, 1)
        XCTAssertNil(options.sourceRevision)
        let invalid: [[String]] = [
            ["--output", "out"], ["--corpus", "c.json"], ["--corpus"],
            ["--corpus", "c.json", "--output", "out", "--mode", "oracle"],
            ["--corpus", "c.json", "--output", "out", "--iterations", "0"],
            ["--corpus", "c.json", "--output", "out", "--live"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try CommandOptions.parse(arguments), "\(arguments)")
        }
        let home = NSHomeDirectory()
        let homeOptions = try XCTUnwrap(CommandOptions.parse(["--corpus", home + "/x.json", "--output", "out"]))
        XCTAssertEqual(homeOptions.corpusPath, "~/x.json")
    }

    func testAppleFMRevisionMatchesThePackagePin() throws {
        for name in ["Package.swift", "Package.resolved"] {
            let text = try String(contentsOf: EvaluationFixture.root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(AppleFMGeneration.revision), name)
        }
    }
}
