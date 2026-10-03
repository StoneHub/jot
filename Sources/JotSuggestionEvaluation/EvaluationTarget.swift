import Foundation
import JotCore

/// The corpus retains its historical shell experiment. Retrieval sees a normal
/// field target; only EvaluationSuggestionPrompt interprets the shell mode.
struct EvaluationTarget: Decodable {
    let mode: EvaluationSuggestionMode
    let value: SuggestionTarget

    init(_ value: SuggestionTarget) {
        self.value = value
        mode = EvaluationSuggestionMode(rawValue: value.mode.rawValue)!
    }

    private enum Keys: String, CodingKey {
        case app, mode, purpose, project, conversation, cwd, inputRevision, before, after, requestedAt, seed, window
    }

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        mode = try keys.decode(EvaluationSuggestionMode.self, forKey: .mode)
        value = SuggestionTarget(app: try keys.decode(String.self, forKey: .app), mode: mode.production ?? .reply,
            purpose: try keys.decode(String.self, forKey: .purpose), project: try keys.decodeIfPresent(String.self, forKey: .project),
            conversation: try keys.decodeIfPresent(String.self, forKey: .conversation), cwd: try keys.decodeIfPresent(String.self, forKey: .cwd),
            inputRevision: try keys.decode(Int.self, forKey: .inputRevision), before: try keys.decode(String.self, forKey: .before),
            after: try keys.decode(String.self, forKey: .after), requestedAt: try keys.decode(String.self, forKey: .requestedAt),
            seed: try keys.decodeIfPresent(String.self, forKey: .seed), window: try keys.decodeIfPresent(String.self, forKey: .window))
    }
}
