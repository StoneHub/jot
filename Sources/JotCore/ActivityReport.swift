import Foundation

/// Counts from retained local history, without transcript content or identities.
public struct ActivityModeSummary: Codable, Sendable, Equatable {
    public let wordCount: Int
    public let timedWordCount: Int
    public let segmentCount: Int
    public let sessionCount: Int
    public let speechWindowSeconds: Double
    public let activeDays: Int
    public let hasCompleteTiming: Bool
    /// Words in positive-duration rows per minute of recorded windows, including pauses.
    public let wordsPerMinute: Double?

    public init(wordCount: Int = 0, timedWordCount: Int? = nil, segmentCount: Int = 0,
                sessionCount: Int = 0, speechWindowSeconds: Double = 0, activeDays: Int = 0,
                hasCompleteTiming: Bool = true) {
        self.wordCount = wordCount
        self.timedWordCount = timedWordCount ?? wordCount
        self.segmentCount = segmentCount
        self.sessionCount = sessionCount
        self.speechWindowSeconds = speechWindowSeconds
        self.activeDays = activeDays
        self.hasCompleteTiming = hasCompleteTiming
        wordsPerMinute = hasCompleteTiming && speechWindowSeconds > 0 ? Double(self.timedWordCount) * 60 / speechWindowSeconds : nil
    }

    private enum CodingKeys: String, CodingKey {
        case wordCount, timedWordCount, segmentCount, sessionCount, speechWindowSeconds, activeDays, hasCompleteTiming, wordsPerMinute
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(wordCount, forKey: .wordCount)
        try values.encode(timedWordCount, forKey: .timedWordCount)
        try values.encode(segmentCount, forKey: .segmentCount)
        try values.encode(sessionCount, forKey: .sessionCount)
        try values.encode(speechWindowSeconds, forKey: .speechWindowSeconds)
        try values.encode(activeDays, forKey: .activeDays)
        try values.encode(hasCompleteTiming, forKey: .hasCompleteTiming)
        try values.encode(wordsPerMinute, forKey: .wordsPerMinute)
    }
}

public struct ActivityDay: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let dictation: ActivityModeSummary
    public let ambient: ActivityModeSummary
    public let verifiedDictationDeliveries: Int

    public init(date: Date, dictation: ActivityModeSummary = .init(), ambient: ActivityModeSummary = .init(),
                verifiedDictationDeliveries: Int = 0) {
        self.date = date; self.dictation = dictation; self.ambient = ambient
        self.verifiedDictationDeliveries = verifiedDictationDeliveries
    }
}

/// A bounded calendar-day report for charts. Today is partial, ending at generatedAt.
public struct ActivityReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let windowStart: Date
    public let windowEnd: Date
    public let days: Int
    public let timeZoneIdentifier: String
    public let dictation: ActivityModeSummary
    public let ambient: ActivityModeSummary
    public let verifiedDictationDeliveries: Int
    public let daily: [ActivityDay]
    public let measurementNotes: [String]

    public init(generatedAt: Date, windowStart: Date, windowEnd: Date, days: Int,
                timeZoneIdentifier: String, dictation: ActivityModeSummary = .init(),
                ambient: ActivityModeSummary = .init(), verifiedDictationDeliveries: Int = 0, daily: [ActivityDay]) {
        schemaVersion = 1
        self.generatedAt = generatedAt; self.windowStart = windowStart; self.windowEnd = windowEnd
        self.days = days; self.timeZoneIdentifier = timeZoneIdentifier
        self.dictation = dictation; self.ambient = ambient
        self.verifiedDictationDeliveries = verifiedDictationDeliveries; self.daily = daily
        measurementNotes = [
            "Retained history only; deleting history changes these totals. No transcript text, audio, speaker names, session identifiers, or app identities are included.",
            "Rows are included and assigned to a local calendar day by their absolute start time, from windowStart through windowEnd. Today is partial. Rows starting before the window are excluded.",
            "Words count whitespace-separated units containing a letter or number in the latest cleaned saved text, falling back to recognized text. This is an approximate text word count, not acoustic evidence.",
            "speechWindowSeconds sums retained row windows, clipped at windowEnd. Windows can include pauses and overlap; they do not measure continuous speech or listening uptime. Cross-midnight windows belong to the day they started.",
            "Dictation and ambient are separate views of saved speech and can overlap. Do not add them to estimate unique spoken words or time.",
            "wordsPerMinute uses timedWordCount from positive-duration rows divided by speechWindowSeconds; zero-duration words are excluded. No duration, or a clipped/nonfinite row end, yields null because full text cannot be attributed to partial time.",
            "sessionCount counts distinct saved session identifiers per mode, not dictation attempts. activeDays counts days with saved rows.",
            "verifiedDictationDeliveries counts retained attempts whose current state is delivered, by latest successful verification updatedAt; retries can change the day. Older history may have no delivery records. This is not every hold or every attempted insertion."
        ]
    }
}

/// Shared validation for the socket endpoint and its MCP tool.
public enum ActivityRequest {
    public static func days(arguments: [String: Any]) throws -> Int {
        for key in arguments.keys where key != "days" { throw MCPToolError.invalid("Unknown argument: \(key)") }
        guard let value = arguments["days"] else { return 7 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == 7 || number.doubleValue == 30 else {
            throw MCPToolError.invalid("days must be 7 or 30")
        }
        return number.intValue
    }
}
