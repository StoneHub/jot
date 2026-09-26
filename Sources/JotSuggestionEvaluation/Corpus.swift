import JotCore
import Foundation

enum EvaluationError: Error, CustomStringConvertible {
    case usage(String), input(String), output(String)
    var description: String {
        switch self {
        case .usage(let message), .input(let message), .output(let message): return message
        }
    }
}

/// The synthetic scenarios in docs/evaluation/contextual-suggestions/scenarios.json.
/// scripts/check-suggestion-fixtures.py checks their structure; this refuses only what the harness cannot run.
struct Corpus: Decodable {
    static let expectedFormat = "jot.contextual-suggestion-scenarios"
    static let supportedVersion = 1

    let format: String
    let version: Int
    let synthetic: Bool
    let scenarios: [CorpusScenario]

    static func decode(_ data: Data) throws -> Corpus {
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.format == expectedFormat, corpus.version == supportedVersion else {
            throw EvaluationError.input("expected a \(expectedFormat) corpus, version \(supportedVersion)")
        }
        guard corpus.synthetic else {
            throw EvaluationError.input("the corpus must be marked synthetic; real content stays out of this experiment")
        }
        guard !corpus.scenarios.isEmpty, Set(corpus.scenarios.map(\.id)).count == corpus.scenarios.count else {
            throw EvaluationError.input("the corpus needs scenarios with unique IDs")
        }
        return corpus
    }
}

/// One authored scenario. Selection, prompts and generation receive only `input`. The oracle serves the
/// explicitly named oracle-context mode and comparisons made after an outcome is recorded.
/// Titles and coverage tags describe the expected behavior, so they are not decoded at all.
struct CorpusScenario: Decodable {
    let id: String
    let target: Target
    let sources: [Source]
    let pendingSuggestion: AuthoredPreview?
    let change: Change?
    let expected: Expected
    let scoring: Scoring

    var input: ScenarioInput { ScenarioInput(target: target, sources: sources) }
    var oracle: ScenarioOracle { ScenarioOracle(expected: expected, scoring: scoring) }
}

struct ScenarioOracle {
    let expected: Expected
    let scoring: Scoring
}

/// The input revision and sources of the corpus's authored preview. Its text is deliberately not decoded.
struct AuthoredPreview: Decodable, Equatable {
    let inputRevision: Int
    let sourceIds: [String]
}

/// Something that happens after a preview is shown and before it could be accepted.
enum Change: Decodable, Equatable {
    case inputEdited(inputRevision: Int, before: String, after: String)
    case sourcesDeleted([String])

    private enum Keys: String, CodingKey { case kind, inputRevision, before, after, sourceIds }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "input-edited":
            let revision = try values.decode(Int.self, forKey: .inputRevision)
            let before = try values.decode(String.self, forKey: .before)
            let after = try values.decode(String.self, forKey: .after)
            self = .inputEdited(inputRevision: revision, before: before, after: after)
        case "source-deleted":
            self = .sourcesDeleted(try values.decode([String].self, forKey: .sourceIds))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "unknown change kind \(kind)")
        }
    }

    var kind: String {
        switch self {
        case .inputEdited: return "input-edited"
        case .sourcesDeleted: return "source-deleted"
        }
    }

    func applied(to input: ScenarioInput) -> ScenarioInput {
        var changed = input
        switch self {
        case let .inputEdited(revision, before, after):
            changed.target.inputRevision = revision
            changed.target.before = before
            changed.target.after = after
        case .sourcesDeleted(let ids):
            for index in changed.sources.indices where ids.contains(changed.sources[index].id) {
                changed.sources[index].status = .deleted
            }
        }
        return changed
    }
}

struct Expected: Decodable {
    struct Exclusion: Decodable, Equatable {
        let id: String
        let reason: String
    }
    let outcome: String
    let includedSources: [String]
    let excludedSources: [Exclusion]
}

struct Scoring: Decodable {
    let criteria: [String]
}
