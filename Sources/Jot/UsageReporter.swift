import Foundation
import JotCore

/// Sends finished days' usage counters to Jot's analytics Worker every few hours, while sharing is on and the Worker is
/// deployed (`UsageReport.endpoint`). A day is sent once. Days that finish while sharing is off are marked as skipped,
/// so turning it back on never sends them, and the first run after install only sets that mark.
@MainActor
final class UsageReporter {
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

    /// A minute after launch, then every six hours. The hour of tolerance lets macOS fold the wake into other work.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            while !Task.isCancelled {
                await self?.report()
                do { try await Task.sleep(for: .seconds(6 * 60 * 60), tolerance: .seconds(60 * 60)) } catch { return }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func report() async {
        guard !running, let store = library.store else { return }
        running = true
        defer { running = false }
        let defaults = settings.defaults
        let calendar = Calendar.current, now = Date()
        guard let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now),
              let oldestDate = calendar.date(byAdding: .day, value: 2 - UsageReport.maximumAgeDays, to: now) else { return }
        let today = TranscriptStore.usageDay(now, calendar: calendar)
        let yesterday = TranscriptStore.usageDay(yesterdayDate, calendar: calendar)
        let markThroughYesterday = { defaults.set(yesterday, forKey: JotDefaultsKey.usageReportedThrough) }
        guard let reportedThrough = defaults.string(forKey: JotDefaultsKey.usageReportedThrough),
              settings.bool(JotDefaultsKey.shareUsage), let endpoint = UsageReport.endpoint else {
            markThroughYesterday()
            return
        }
        guard reportedThrough < yesterday else { return }
        let first = max(reportedThrough, TranscriptStore.usageDay(oldestDate, calendar: calendar))
        guard let counts = try? await library.storeExecutor.perform({ try store.usageCounts(from: first, through: yesterday) }) else { return }
        guard let report = UsageReport.due(counts: counts, today: today, reportedThrough: reportedThrough,
                                           app: JotVersion.current, os: UsageReport.osVersion, arch: UsageReport.arch),
              let body = try? JSONEncoder().encode(report) else {
            markThroughYesterday()
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let result = try? await session.data(for: request),
              let status = (result.1 as? HTTPURLResponse)?.statusCode else { return }
        // A refused report would be refused again, so it is marked like an accepted one. Server errors and rate limits retry later.
        if (200..<500).contains(status), status != 429 { markThroughYesterday() }
    }
}
