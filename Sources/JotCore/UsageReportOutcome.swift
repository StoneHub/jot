import Foundation

/// What Jot's last usage report did, kept so `jot status` and the system log can say whether analytics reach the
/// Worker. Without it a day marked as reported looks the same whether it was sent, refused or had nothing to send.
/// It holds day keys, an HTTP status and the Worker's short refusal reason: never counts, text or anything about the Mac.
public struct UsageReportOutcome: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable {
        /// The Worker stored the days.
        case sent
        /// The Worker refused the report (a 4xx other than 429). The days are marked as sent, since they would be refused again.
        case refused
        /// No answer, a server error or a rate limit. Nothing is marked, so the days are tried again later.
        case failed
        /// Finished days were due but none had counts, so they were marked without a request.
        case nothingToSend
        /// Sharing is off, so finished days were marked as skipped without a request.
        case sharingOff
        /// The first run after install only marks yesterday as done.
        case firstRun
    }

    public let at: Date
    public let result: Result
    /// The days the report carried, oldest first; empty when no request was made.
    public let days: [String]
    public let httpStatus: Int?
    /// The Worker's reason for a refusal ("invalid count"), or why a request failed. At most `maximumDetail` characters.
    public let detail: String?

    public static let maximumDetail = 80

    public init(at: Date, result: Result, days: [String] = [], httpStatus: Int? = nil, detail: String? = nil) {
        self.at = at
        self.result = result
        self.days = days
        self.httpStatus = httpStatus
        self.detail = detail.map(Self.clean)
    }

    /// The outcome for an HTTP answer to a report of `days`: 2xx sent, 429 or 5xx failed (retried later), other 4xx
    /// refused with the Worker's reason from `body`.
    public static func answer(_ status: Int, body: Data, days: [String], at: Date) -> UsageReportOutcome {
        let result: Result = (200..<300).contains(status) ? .sent : (400..<500).contains(status) && status != 429 ? .refused : .failed
        let reason = result == .sent ? nil : String(decoding: body.prefix(4 * maximumDetail), as: UTF8.self)
        return UsageReportOutcome(at: at, result: result, days: days, httpStatus: status, detail: reason?.isEmpty == false ? reason : nil)
    }

    /// Whether the reporter marks the report's days as done: everything except a failure, which is retried.
    public var marksDays: Bool { result != .failed }

    /// One line for the system log.
    public var summary: String {
        var line = result.rawValue
        if let first = days.first, let last = days.last { line += first == last ? " \(first)" : " \(first)...\(last)" }
        if let httpStatus { line += " (HTTP \(httpStatus))" }
        if let detail { line += ": \(detail)" }
        return line
    }

    /// Printable ASCII only, one line, cut to `maximumDetail`: a proxy's HTML page must not spill into the log or status.
    static func clean(_ text: String) -> String {
        let line = text.unicodeScalars.map { (0x20..<0x7F).contains($0.value) ? Character($0) : " " }
        return String(String(line).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ").prefix(maximumDetail))
    }

    /// The stored form under `JotDefaultsKey.usageLastReport`.
    public func encoded() -> Data? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func decoded(_ data: Data?) -> UsageReportOutcome? {
        guard let data else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageReportOutcome.self, from: data)
    }
}
