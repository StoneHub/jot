import Foundation
import AppleFM
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One local request at a time, with no cleanup backlog and a caller deadline.
/// A slow model may finish cancelling after the deadline; later calls then bypass it.
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
            let completion = OneShotCompletion(continuation)
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
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: settings.int(JotSettings.cleanupMaximumTokens))).texts
        }
        #endif
        return texts
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct CleanedTranscripts {
    var texts: [String]
}
#endif
