import Foundation
import JotCore
import OSLog

/// Sends finished days' usage counters to Jot's analytics Worker every few hours, while sharing is on and the Worker is
/// deployed (`UsageReport.endpoint`). A day is sent once. Days that finish while sharing is off are marked as skipped,
/// so turning it back on never sends them, and the first run after install only sets that mark.
@MainActor
final class UsageReporter {
    private static let log = Logger(subsystem: "space.jot.app", category: "usage-report")
    private let library: SessionLibrary
    private let settings: JotSettings
    private var loop: Task<Void, Never>?
    private var running = false
    /// No cookies, cache or credentials: a report carries only its JSON body.
    private let session = URLSession(configuration: .ephemeral)

    init(library: SessionLibrary, settings: JotSettings) {
        self.library = library
        self.settings = settings
    }

    deinit {
        loop?.cancel()
        session.invalidateAndCancel()
    }

    /// A minute after launch, then every six hours. The hour of tolerance lets macOS fold the wake into other work.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            while !Task.isCancelled {
                if let self { self.countFeatures(); await self.report() } else { return }
                do { try await Task.sleep(for: .seconds(6 * 60 * 60), tolerance: .seconds(60 * 60)) } catch { return }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// Counts the features that are on, once a local day, so each day Jot ran says which features this Mac kept on.
    private func countFeatures() {
        let today = TranscriptStore.usageDay(Date(), calendar: .current)
        guard settings.defaults.string(forKey: JotDefaultsKey.featuresCountedDay) != today else { return }
        settings.defaults.set(today, forKey: JotDefaultsKey.featuresCountedDay)
        library.countUsage(UsageCounter.features(in: settings))
    }

    private func report() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let defaults = settings.defaults
        let calendar = Calendar.current, now = Date()
        guard let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now),
              let oldestDate = calendar.date(byAdding: .day, value: 2 - UsageReport.maximumAgeDays, to: now) else { return }
        let today = TranscriptStore.usageDay(now, calendar: calendar)
        let yesterday = TranscriptStore.usageDay(yesterdayDate, calendar: calendar)
        let markThroughYesterday = { defaults.set(yesterday, forKey: JotDefaultsKey.usageReportedThrough) }
        guard let reportedThrough = defaults.string(forKey: JotDefaultsKey.usageReportedThrough) else {
            markThroughYesterday()
            record(UsageReportOutcome(at: now, result: .firstRun))
            return
        }
        guard reportedThrough < yesterday else { return }
        guard settings.bool(JotDefaultsKey.shareUsage), let endpoint = UsageReport.endpoint else {
            markThroughYesterday()
            record(UsageReportOutcome(at: now, result: .sharingOff))
            return
        }
        guard let store = library.store else {
            record(UsageReportOutcome(at: now, result: .failed, detail: "history is not open"))
            return
        }
        let first = max(reportedThrough, TranscriptStore.usageDay(oldestDate, calendar: calendar))
        let counts: [String: [String: Int]]
        do {
            counts = try await library.storeExecutor.perform { try store.usageCounts(from: first, through: yesterday) }
        } catch {
            record(UsageReportOutcome(at: now, result: .failed, detail: "could not read usage counts"))
            return
        }
        guard let report = UsageReport.due(counts: counts, today: today, reportedThrough: reportedThrough,
                                           app: JotVersion.current, os: UsageReport.osVersion, arch: UsageReport.arch),
              let body = try? JSONEncoder().encode(report) else {
            markThroughYesterday()
            record(UsageReportOutcome(at: now, result: .nothingToSend))
            return
        }
        let days = report.days.map(\.day)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let outcome: UsageReportOutcome
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                record(UsageReportOutcome(at: now, result: .failed, days: days, detail: "no HTTP response"))
                return
            }
            outcome = UsageReportOutcome.answer(status, body: data, days: days, at: now)
        } catch {
            let code = (error as? URLError)?.code.rawValue ?? 0
            record(UsageReportOutcome(at: now, result: .failed, days: days, detail: "network error \(code)"))
            return
        }
        // A refused report would be refused again, so it is marked like an accepted one. Server errors and rate limits retry later.
        if outcome.marksDays { markThroughYesterday() }
        record(outcome)
    }

    /// Keeps the outcome for `jot status` and writes it to the system log
    /// (`log show --predicate 'subsystem == "space.jot.app" AND category == "usage-report"'`).
    private func record(_ outcome: UsageReportOutcome) {
        if let data = outcome.encoded() { settings.defaults.set(data, forKey: JotDefaultsKey.usageLastReport) }
        Self.log.notice("usage report \(outcome.summary, privacy: .public)")
    }
}
