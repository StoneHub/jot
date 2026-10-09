import Foundation

/// One settings variant for `jot lab`: a name and the transcription settings it changes from the app's current values.
/// Variants that differ only in grouping settings share one recognition run; the rest each run recognition again.
public struct LabVariant: Codable, Sendable, Equatable {
    /// A setting value as the variants file gives it, before `JotSettings` validates it.
    public enum Value: Codable, Sendable, Equatable {
        case bool(Bool), number(Double), text(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .text(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            }
        }

        var raw: Any {
            switch self {
            case .bool(let value): value
            case .number(let value): value
            case .text(let value): value
            }
        }
    }

    public var name: String
    public var settings: [String: Value]

    public init(name: String, settings: [String: Value]) { self.name = name; self.settings = settings }

    /// Applied to the recognition that is already saved: these regroup stored words and need no new run.
    public static let groupingKeys: Set<String> = [JotSettings.speakerConfidence, JotSettings.minimumSpeakerTurn, JotSettings.paragraphPause]
    /// Capture, recognition and cleanup: a variant that changes one of these gets its own recognition run.
    public static let recognitionKeys: Set<String> = [
        JotSettings.chunkMaximumSeconds, JotSettings.chunkSilenceSeconds, JotSettings.silenceLevel, JotSettings.speechGate,
        JotSettings.dropFillerOnlyBlocks, JotDefaultsKey.cleanUpTranscriptions, JotSettings.phrasePause, JotSettings.phraseMaximumSeconds,
        JotSettings.phraseMinimumWords, JotSettings.cleanupMaximumTokens, JotSettings.cleanupInstructions,
    ]

    /// Reads a variants file: a JSON array of `{"name": …, "settings": {key: value}}`, keys as `jot settings` lists them.
    public static func parse(_ data: Data) throws -> [LabVariant] {
        let variants: [LabVariant]
        do { variants = try JSONDecoder().decode([LabVariant].self, from: data) }
        catch { throw LabError.invalid("The variants file must be a JSON array of {\"name\": …, \"settings\": {…}}: \(error.localizedDescription)") }
        guard !variants.isEmpty else { throw LabError.invalid("The variants file has no variants.") }
        var names: Set<String> = []
        for variant in variants {
            let name = variant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 64 else { throw LabError.invalid("Each variant needs a name of 1 to 64 characters.") }
            guard names.insert(name).inserted else { throw LabError.invalid("Two variants are named \(name).") }
            for key in variant.settings.keys {
                guard JotSettings.definition(key) != nil else { throw LabError.invalid("\(name): \(key) is not a Jot setting.") }
                guard groupingKeys.contains(key) || recognitionKeys.contains(key) else {
                    throw LabError.invalid("\(name): \(key) does not change transcription, so the lab cannot compare it.")
                }
            }
        }
        return variants
    }

    /// The settings a recognition run records under: this variant's without its grouping settings, which apply only afterwards.
    /// Live recognition splits stored rows by its grouping and a regroup never merges them back, so a shared run records
    /// under the base grouping whichever variant comes first.
    public var recognitionSettings: LabVariant {
        LabVariant(name: name, settings: settings.filter { !Self.groupingKeys.contains($0.key) })
    }

    /// Variants grouped by the recognition run they need, in file order: each group differs only in grouping settings.
    public static func recognitionRuns(_ variants: [LabVariant]) -> [[LabVariant]] {
        var order: [[String: Value]] = []
        var groups: [[LabVariant]] = []
        for variant in variants {
            let recognition = variant.recognitionSettings.settings
            if let index = order.firstIndex(of: recognition) { groups[index].append(variant) }
            else { order.append(recognition); groups.append([variant]) }
        }
        return groups
    }

    /// Writes this variant's values over `settings`, validated and clamped as `jot settings set` does.
    public func apply(to settings: JotSettings) throws {
        for (key, value) in self.settings.sorted(by: { $0.key < $1.key }) {
            do { try settings.set(key, raw: value.raw) }
            catch { throw LabError.invalid("\(name): \(error.localizedDescription)") }
        }
    }
}
