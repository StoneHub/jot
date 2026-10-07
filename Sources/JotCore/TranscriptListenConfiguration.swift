import Foundation

/// Local filtering only. Quiet means no new matching-speaker rows, not microphone silence.
public struct TranscriptListenConfiguration: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable { case fast, command, context, all }
    public static let defaultWakePhrases = "claude"
    public static let defaultMode = Mode.command
    public static let defaultQuietGap = 6.0
    public static let defaultLookbackMinutes = 5
    public var wakePhrases: [String]
    public var mode: Mode
    public var quietGap: Double
    public var lookbackMinutes: Int

    public init(wakePhrases: [String] = [defaultWakePhrases], mode: Mode = defaultMode,
                quietGap: Double = defaultQuietGap, lookbackMinutes: Int = defaultLookbackMinutes) {
        self.wakePhrases = Self.phrases(wakePhrases.joined(separator: ",")) ?? [Self.defaultWakePhrases]
        self.mode = mode
        self.quietGap = quietGap.isFinite ? min(60, max(3, quietGap)) : Self.defaultQuietGap
        self.lookbackMinutes = min(60, max(1, lookbackMinutes))
    }

    /// Commas separate aliases. Invalid saved settings fall back; explicit CLI options are refused.
    public static func phrases(_ text: String) -> [String]? {
        guard text.count <= 1024 else { return nil }
        let values = text.components(separatedBy: ",").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard !values.isEmpty, values.count <= 16,
              values.allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }) else { return nil }
        return values
    }
}
