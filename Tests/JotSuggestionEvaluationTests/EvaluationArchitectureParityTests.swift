import XCTest
import JotCore
@testable import JotSuggestionEvaluation

final class EvaluationArchitectureParityTests: XCTestCase {
    @MainActor func testCommittedCorpusSelectionAndPromptParity() async throws {
        let corpus = try EvaluationFixture.corpus()
        var signatures: [String] = []
        for mode in [EvaluationMode.normal, .oracleContext] {
            for (limits, association) in [(EvaluationLimits.experiment, EvaluationAssociation.scoped), (.window, .explicit)] {
                let configuration = EvaluationConfiguration(mode: mode, generatorLabel: "test-fake", limits: limits, association: association)
                let evaluation = SuggestionEvaluation(configuration: configuration, generator: EvaluationFixture.fakeGenerator)
                try await evaluation.run(corpus) { record in
                    let selected = record.selection.selected.map { $0.id }.joined(separator: ",")
                    let excluded = record.selection.excluded.map { $0.id + ":" + $0.reason.rawValue }.joined(separator: ",")
                    signatures.append([record.scenarioID, selected, excluded, record.request?.sha256 ?? "none"].joined(separator: "|"))
                }
            }
        }
        let digest = ContentHash.sha256(signatures.joined(separator: "\n"))
        XCTAssertEqual(signatures.count, 108)
        XCTAssertEqual(digest, "f257f323ba02389c89461bbd030a4b321db8a1e0ed0a549e2cfaf8157f16ddc0")
    }
}
