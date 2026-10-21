import Foundation

/// One anonymous report of finished days' usage counters, in the shape the analytics Worker accepts
/// (services/analytics, docs/ANALYTICS.md). It carries counter names and counts, the Jot and macOS versions and the
/// CPU architecture: no install ID, text, app names or anything else that could identify a Mac or what was said.
public struct UsageReport: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public let day: String
        public let counters: [String: Int]
    }

    public let schema: Int
    public let app: String
    public let os: String
    public let arch: String
    public let days: [Day]

    /// The deployed Worker's report URL. Nil until the Worker is deployed, and nothing is sent while it is nil.
    public static let endpoint: URL? = nil
    /// The Worker refuses more days than this in one report and days older than `maximumAgeDays`; the reporter reads a
    /// little less than that, since the Worker's date can run up to a day ahead of the Mac's.
    public static let maximumDays = 7
    public static let maximumAgeDays = 35

    /// Days to send: finished local days after `reportedThrough`, newest `maximumDays` of them, skipping days with no
    /// counts. Day keys are `yyyy-MM-dd`, so they compare as text. Nil when nothing is due or a version string is one
    /// the Worker would refuse.
    public static func due(counts: [String: [String: Int]], today: String, reportedThrough: String,
                           app: String, os: String, arch: String) -> UsageReport? {
        guard [app, os].allSatisfy(isVersion), ["arm64", "x86_64"].contains(arch) else { return nil }
        let names = Set(UsageCounter.allCases.map(\.name))
        let days = counts.keys.filter { $0 > reportedThrough && $0 < today }.sorted().compactMap { day -> Day? in
            // Only names this build can produce; the Worker refuses a report with any other.
            let counters = (counts[day] ?? [:]).filter { names.contains($0.key) && $0.value > 0 }
            return counters.isEmpty ? nil : Day(day: day, counters: counters)
        }.suffix(maximumDays)
        return days.isEmpty ? nil : UsageReport(schema: 1, app: app, os: os, arch: arch, days: Array(days))
    }

    /// Digits and dots only, as the Worker requires: "0.3.4", "26.1".
    static func isVersion(_ value: String) -> Bool {
        value.range(of: #"^\d{1,4}(\.\d{1,4}){0,3}$"#, options: .regularExpression) != nil
    }

    /// This Mac's macOS version as major.minor, with the patch when there is one.
    public static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

extension TranscriptStore {
    /// The local day key for a date, as the usage counters store it.
    public static func usageDay(_ date: Date, calendar: Calendar = .current) -> String {
        UsageCounterRows.day(date, calendar: calendar)
    }
}
