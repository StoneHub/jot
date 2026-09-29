import Foundation
import AppleFM
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum CleanupAvailability: String, Sendable, CaseIterable {
    case available, olderSystem, deviceNotEligible, notEnabled, modelNotReady
    public var explanation: String {
        switch self {
        case .available: return "Uses Apple Intelligence on this Mac to make captured speech more readable."
        case .olderSystem: return "Apple cleanup requires macOS 26 or later. Transcription works without it."
        case .deviceNotEligible: return "Apple cleanup is unavailable on this Mac. Transcription works without it."
        case .notEnabled: return "Apple Intelligence is off in macOS. Transcription works without cleanup."
        case .modelNotReady: return "Apple Intelligence is not ready. Transcription works without cleanup."
        }
    }

    public var suggestionBlocker: String? {
        switch self {
        case .available: return nil
        case .olderSystem: return "Suggestions require macOS 26 or later. Dictation and saved text still work."
        case .deviceNotEligible: return "Suggestions are unavailable on this Mac. Dictation and saved text still work."
        case .notEnabled: return "Apple Intelligence is off in macOS. Dictation and saved text still work."
        case .modelNotReady: return "Apple Intelligence is not ready. Dictation and saved text still work."
        }
    }
}

/// Rejects known dangerous edits. This is a conservative fallback, not a proof of semantic equivalence.
public enum CleanupValidation {
    public static func accepts(_ candidate: String, source: String) -> Bool {
        let output = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.utf8.count <= max(120, source.utf8.count * 2) else { return false }
        let numbers = Set("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third half quarter percent point".split(separator: " ").map(String.init))
        let qualifiers = Set("no not never cannot can't don't doesn't didn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't hasn't hadn't maybe probably possibly might unless".split(separator: " ").map(String.init))
        func protected(_ text: String) -> [String] {
            let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'.,")).inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.filter { !$0.isEmpty }
            var result: [String] = []
            for word in words where numbers.contains(word) || qualifiers.contains(word) || word.contains(where: \.isNumber) {
                if result.last != word { result.append(word) }
            }
            return result
        }
        return protected(source) == protected(output)
    }
}

/// One local request at a time, with no cleanup backlog and a caller deadline.
/// A slow model may finish cancelling after the deadline; later calls then bypass it.
public struct CleanupResult: Sendable {
    public enum Outcome: String, Sendable {
        case changed, unchanged, busy, cancelled, empty, oversized, unavailable
        case invalidCount, rejectedEdits, modelError, timedOut
    }
    public let texts: [String]
    public let outcome: Outcome
}

@MainActor
public final class TranscriptCleanup {
    public enum Purpose { case transcript, dictation }
    public typealias Generator = @Sendable ([String]) async throws -> [String]
    private var busy = false
    private var interrupt: (() -> Void)?
    /// Live phrases and dictation share user settings; dictation also keeps fragments as fragments.
    private let settings: JotSettings
    private let purpose: Purpose
    private let modelAvailability: @MainActor () -> CleanupAvailability
    public init(settings: JotSettings = .standard, purpose: Purpose = .transcript,
                availability: @escaping @MainActor () -> CleanupAvailability = { TranscriptCleanup.availability }) {
        self.settings = settings
        self.purpose = purpose
        self.modelAvailability = availability
    }

    var instructions: String {
        let base = settings.text(JotSettings.cleanupInstructions)
        guard purpose == .dictation else { return base }
        let editing = base == JotSettings.defaultCleanupInstructions
            ? base.replacingOccurrences(of: "use sentence capitalization and add punctuation and paragraph breaks",
                                        with: "use appropriate capitalization and paragraph breaks")
            : base
        return editing + " This is held dictation inserted at a cursor, which may be inside existing text. First decide whether each entry is a complete sentence or a fragment. Add sentence-ending punctuation only for complete sentences. A noun phrase such as 'the blue one' or a time phrase such as 'tomorrow morning' is a fragment. Remove a recognizer-added final period from a fragment; an existing period is not evidence of a complete sentence. Keep fragment capitalization and never expand a fragment into a sentence. Examples: 'purple' stays 'purple'; 'the blue one.' becomes 'the blue one'; 'tomorrow morning.' becomes 'tomorrow morning'; 'I want the blue one' becomes 'I want the blue one.'; 'Go now' becomes 'Go now.'. Preserve explicit symbols, abbreviations, decimals, URLs and preferred spellings."
    }

    /// Release a waiting speech worker immediately when dictation takes priority.
    public func cancel() { interrupt?() }

    public static var availability: CleanupAvailability {
        switch AppleFMClient().modelAvailability {
        case .available: return .available
        case .unsupportedOS: return .olderSystem
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady, .unavailable: return .modelNotReady
        }
    }

    public func clean(_ texts: [String], timeout: Duration = .seconds(2), generator: Generator? = nil) async -> [String] {
        await cleanWithOutcome(texts, timeout: timeout, generator: generator).texts
    }

    /// Metadata explains a fallback without exposing the input or model error text.
    public func cleanWithOutcome(_ texts: [String], timeout: Duration = .seconds(2), generator: Generator? = nil) async -> CleanupResult {
        if Task.isCancelled { return .init(texts: texts, outcome: .cancelled) }
        if busy { return .init(texts: texts, outcome: .busy) }
        if texts.isEmpty { return .init(texts: texts, outcome: .empty) }
        if texts.reduce(0, { $0 + $1.utf8.count }) > 2400 { return .init(texts: texts, outcome: .oversized) }
        if modelAvailability() != .available { return .init(texts: texts, outcome: .unavailable) }
        busy = true
        return await withCheckedContinuation { continuation in
            let completion = CleanupCompletion(continuation)
            let request = Task {
                defer { busy = false; interrupt = nil }
                do {
                    let result: [String]
                    if let generator { result = try await generator(texts) }
                    else { result = try await generate(texts) }
                    if Task.isCancelled {
                        completion.finish(.init(texts: texts, outcome: .cancelled))
                    } else if result.count != texts.count {
                        completion.finish(.init(texts: texts, outcome: .invalidCount))
                    } else {
                        var rejected = false
                        let accepted = zip(result, texts).map { candidate, source in
                            if CleanupValidation.accepts(candidate, source: source) {
                                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            rejected = true
                            return source
                        }
                        completion.finish(.init(texts: accepted,
                            outcome: rejected ? .rejectedEdits : (accepted == texts ? .unchanged : .changed)))
                    }
                } catch { completion.finish(.init(texts: texts, outcome: Task.isCancelled ? .cancelled : .modelError)) }
            }
            interrupt = {
                completion.finish(.init(texts: texts, outcome: .cancelled))
                request.cancel()
            }
            Task {
                try? await Task.sleep(for: timeout)
                if completion.finish(.init(texts: texts, outcome: .timedOut)) { request.cancel() }
            }
        }
    }

    private func generate(_ texts: [String]) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let input = String(decoding: try JSONEncoder().encode(texts), as: UTF8.self)
            return try await AppleFMClient().generate(instructions: instructions, prompt: input,
                generating: CleanedTranscripts.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: settings.int(JotSettings.cleanupMaximumTokens))).texts
        }
        #endif
        return texts
    }
}

@MainActor
private final class CleanupCompletion {
    private var continuation: CheckedContinuation<CleanupResult, Never>?
    init(_ continuation: CheckedContinuation<CleanupResult, Never>) { self.continuation = continuation }
    @discardableResult func finish(_ value: CleanupResult) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct CleanedTranscripts {
    var texts: [String]
}
#endif
