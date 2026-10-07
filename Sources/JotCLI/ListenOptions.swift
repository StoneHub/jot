import Foundation
import JotCore

struct ListenOptions {
    var mode: TranscriptListenConfiguration.Mode?
    var wakePhrases: [String]?
    var quietGap: Double?
    var lookbackMinutes: Int?
    var once = false
    var timeout: Double?
    static let usage = "Use: jot listen [--mode fast|command|context|all] [--wake phrase[,alias]] [--quiet-gap S] [--lookback-minutes N] [--once] [--timeout S]"

    init(_ args: [String]) throws {
        var index = 0, seen: Set<String> = []
        while index < args.count {
            let flag = args[index]
            guard seen.insert(flag).inserted else { throw ListenError("Repeated option: " + flag) }
            if flag == "--once" { once = true; index += 1; continue }
            guard index + 1 < args.count else { throw ListenError(Self.usage) }
            let value = args[index + 1]
            switch flag {
            case "--mode":
                guard let parsed = TranscriptListenConfiguration.Mode(rawValue: value) else { throw ListenError("--mode needs fast, command, context or all") }
                mode = parsed
            case "--wake":
                guard let parsed = TranscriptListenConfiguration.phrases(value) else { throw ListenError("--wake needs 1...16 comma-separated phrases of 1...80 characters") }
                wakePhrases = parsed
            case "--quiet-gap":
                guard let parsed = Double(value), parsed.isFinite, (3...60).contains(parsed) else { throw ListenError("--quiet-gap needs seconds from 3 to 60") }
                quietGap = parsed
            case "--lookback-minutes":
                guard let parsed = Int(value), (1...60).contains(parsed) else { throw ListenError("--lookback-minutes needs an integer from 1 to 60") }
                lookbackMinutes = parsed
            case "--timeout":
                guard let parsed = Double(value), parsed.isFinite, parsed >= 0, parsed <= 86_400 else { throw ListenError("--timeout needs seconds from 0 to 86400") }
                timeout = parsed
            default: throw ListenError(Self.usage)
            }
            index += 2
        }
    }

    func configuration(_ settings: [[String: Any]]) -> TranscriptListenConfiguration {
        let values = Dictionary(settings.compactMap { row -> (String, Any)? in
            guard let key = row["key"] as? String, let value = row["value"] else { return nil }
            return (key, value)
        }, uniquingKeysWith: { _, latest in latest })
        return .init(wakePhrases: wakePhrases ?? TranscriptListenConfiguration.phrases(values[JotSettings.listenWakePhrases] as? String ?? "") ?? [TranscriptListenConfiguration.defaultWakePhrases],
                     mode: mode ?? TranscriptListenConfiguration.Mode(rawValue: values[JotSettings.listenMode] as? String ?? "") ?? .command,
                     quietGap: quietGap ?? (values[JotSettings.listenQuietGap] as? Double) ?? TranscriptListenConfiguration.defaultQuietGap,
                     lookbackMinutes: lookbackMinutes ?? (values[JotSettings.listenLookbackMinutes] as? Int) ?? TranscriptListenConfiguration.defaultLookbackMinutes)
    }
}
