import XCTest
@testable import JotCore

final class PerformanceDiagnosticsTests: XCTestCase {
    private func sample(_ elapsed: Double, footprint: Double = 100) -> PerformanceSample {
        .init(elapsedSeconds: elapsed, footprintMiB: footprint, residentMiB: 200, cpuPercent: 0)
    }
    func testSamplingCadenceCapsAndLifetimeBaseline() {
        var diagnostics = PerformanceDiagnostics()
        for second in 0...90_000 { diagnostics.observe(sample(Double(second), footprint: second == 1 ? 999 : 100)) }
        let report = diagnostics.report
        XCTAssertEqual(report.samples.count, PerformanceDiagnostics.sampleCapacity)
        XCTAssertEqual(report.samples.last?.elapsedSeconds, 90_000)
        XCTAssertEqual(report.startup?.elapsedSeconds, 0)
        XCTAssertEqual(report.sampledPeakFootprintMiB, 999)
        XCTAssertEqual(report.current?.footprintMiB, 100)
        XCTAssertEqual(report.samples[1].elapsedSeconds - report.samples[0].elapsedSeconds, 30)
    }
    func testInvalidAndOutOfOrderSamplesDoNotCorruptHistory() throws {
        var diagnostics = PerformanceDiagnostics()
        diagnostics.observe(sample(10))
        diagnostics.observe(sample(9, footprint: 999))
        diagnostics.observe(sample(20, footprint: .nan))
        XCTAssertEqual(diagnostics.report.current?.elapsedSeconds, 10)
        XCTAssertNoThrow(try diagnostics.export())
    }
    func testBoundedEventsJobsAndLatencyPopulations() {
        var diagnostics = PerformanceDiagnostics()
        for i in 0..<300 {
            diagnostics.mark(.dictationStarted, at: Double(i))
            diagnostics.record(.init(elapsedSeconds: Double(i), mode: .dictation, outcome: .completed,
                audioSeconds: 3, queueWaitSeconds: 0, inferenceSeconds: 0.2, completionSeconds: Double(i)))
        }
        XCTAssertEqual(diagnostics.report.events.count, 256)
        XCTAssertEqual(diagnostics.report.jobs.count, 200)
        XCTAssertEqual(diagnostics.report.dictationLatency.count, 200)
        XCTAssertEqual(diagnostics.report.dictationLatency.medianSeconds, 199.5)
        XCTAssertEqual(diagnostics.report.dictationLatency.p95Seconds, 289)
        diagnostics.record(.init(elapsedSeconds: 301, mode: .dictation, outcome: .failed,
            audioSeconds: 3, queueWaitSeconds: 0, inferenceSeconds: nil, completionSeconds: 10000))
        XCTAssertEqual(diagnostics.report.dictationLatency.count, 199)
        XCTAssertEqual(diagnostics.report.dictationLatency.p95Seconds, 290)
    }
    func testDictationLatencyIsSplitByWhetherCleanupRan() throws {
        var diagnostics = PerformanceDiagnostics()
        func dictation(_ outcome: PerformanceJob.Outcome, completion: Double, cleanup: Double? = nil, cleanupOutcome: String? = nil) {
            diagnostics.record(.init(elapsedSeconds: 1, mode: .dictation, outcome: outcome, audioSeconds: 2, queueWaitSeconds: 0.1,
                inferenceSeconds: nil, completionSeconds: completion, cleanupSeconds: cleanup, deliverySeconds: 0.05, cleanupOutcome: cleanupOutcome))
        }
        // Ten inserted dictations: five cleaned, five not.
        for (index, completion) in [1.0, 1.4, 1.2, 3.0, 1.6].enumerated() {
            dictation(index == 3 ? .deliveryUnverified : .completed, completion: completion, cleanup: completion - 0.2, cleanupOutcome: index == 4 ? "unchanged" : "changed")
        }
        for completion in [0.3, 0.2, 0.5, 0.4, 0.9] { dictation(.completed, completion: completion) }
        // Not inserted: excluded from release-to-insert latency, while the cleanup they ran still counts.
        dictation(.noSpeech, completion: 0.1)
        dictation(.failed, completion: 20, cleanup: 12, cleanupOutcome: "timedOut")
        dictation(.cancelled, completion: 30)
        diagnostics.record(.init(elapsedSeconds: 1, mode: .ambient, outcome: .completed, audioSeconds: 3, queueWaitSeconds: 0,
            inferenceSeconds: 0.2, completionSeconds: 50))
        let report = try JSONDecoder().decode(PerformanceReport.self, from: diagnostics.export())
        XCTAssertEqual(report.dictationLatency.count, 10)
        XCTAssertEqual(report.dictationLatency.medianSeconds ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(report.dictationLatency.p95Seconds, 3.0)
        XCTAssertEqual(report.dictationLatencyWithCleanup.count, 5)
        XCTAssertEqual(report.dictationLatencyWithCleanup.medianSeconds, 1.4)
        XCTAssertEqual(report.dictationLatencyWithCleanup.p95Seconds, 3.0)
        XCTAssertEqual(report.dictationLatencyWithoutCleanup.count, 5)
        XCTAssertEqual(report.dictationLatencyWithoutCleanup.medianSeconds, 0.4)
        XCTAssertEqual(report.dictationLatencyWithoutCleanup.p95Seconds, 0.9)
        XCTAssertEqual(report.dictationCleanupLatency.count, 6)
        XCTAssertEqual(report.dictationCleanupLatency.p95Seconds, 12)
        let failed = try XCTUnwrap(report.jobs.first { $0.outcome == .failed })
        XCTAssertEqual(failed.cleanupOutcome, "timedOut")
        XCTAssertEqual(failed.deliverySeconds, 0.05)
    }
    func testExportSchemaContainsOnlyApprovedMetrics() throws {
        var diagnostics = PerformanceDiagnostics()
        diagnostics.observe(sample(0))
        diagnostics.mark(.launch, at: 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnostics.export()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["build", "schemaVersion", "sampleIntervalSeconds", "sampleCapacity", "eventCapacity", "jobCapacity", "startup", "current", "sampledPeakFootprintMiB", "samples", "events", "jobs", "dictationLatency", "dictationLatencyWithCleanup", "dictationLatencyWithoutCleanup", "dictationCleanupLatency", "inferenceLatency"]))
        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual(Set(current.keys), Set(["elapsedSeconds", "footprintMiB", "residentMiB", "cpuPercent", "droppedAudioSeconds", "bufferedAudioSeconds", "queuedAudioSeconds", "loadedHistoryRows", "modelsReady", "ambientEnabled", "dictationActive", "inferenceRunning"]))
        XCTAssertNil(LatencySummary([]).medianSeconds)
        XCTAssertEqual(LatencySummary([1, 2, 3, 4]).medianSeconds, 2.5)
    }
}
