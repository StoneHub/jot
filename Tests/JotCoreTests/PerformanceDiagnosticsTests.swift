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
    /// The CPU seconds of kept samples, each covering the interval since the kept sample before it.
    private func keptCPUSeconds(_ samples: [PerformanceSample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { $0 + $1.1.cpuPercent / 100 * ($1.1.elapsedSeconds - $1.0.elapsedSeconds) }
    }
    func testKeptSampleCPUCoversTheWholeIntervalSinceThePreviousKeptSample() {
        var diagnostics = PerformanceDiagnostics()
        func observe(_ elapsed: Double, cpu: Double) {
            diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: 100, residentMiB: 200, cpuPercent: cpu))
        }
        observe(0, cpu: 0)
        observe(10, cpu: 50)     // 5 CPU seconds
        observe(29.5, cpu: 0)
        observe(30, cpu: 100)    // 0.5 CPU seconds, just after a recognition; kept
        observe(45, cpu: 20)     // 3 CPU seconds
        observe(60, cpu: 0)      // kept
        let samples = diagnostics.report.samples
        XCTAssertEqual(samples.map(\.elapsedSeconds), [0, 30, 60])
        XCTAssertEqual(samples[1].cpuPercent, 5.5 / 30 * 100, accuracy: 1e-9)
        XCTAssertEqual(samples[2].cpuPercent, 3.0 / 30 * 100, accuracy: 1e-9)
        XCTAssertEqual(keptCPUSeconds(samples), 8.5, accuracy: 1e-9)
        XCTAssertEqual(diagnostics.report.current?.cpuPercent, 0, "The current sample keeps its own reading")
    }
    /// Samples like the app's: a short one after each burst of work between idle stretches. Elapsed time is scaled so the 30-second cadence passes in a fraction of a second; scaling time leaves each percentage unchanged.
    func testKeptSampleCPUAddsUpToTheKernelCount() throws {
        func kernelCPUSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        }
        let scale = 200.0
        var diagnostics = PerformanceDiagnostics()
        let began = ProcessInfo.processInfo.systemUptime
        var previous = (time: began, cpu: kernelCPUSeconds())
        var kernelAt: [Double: Double] = [:]
        func observe() {
            let now = ProcessInfo.processInfo.systemUptime, cpu = kernelCPUSeconds()
            let elapsed = (now - began) * scale
            kernelAt[elapsed] = cpu
            diagnostics.observe(.init(elapsedSeconds: elapsed, footprintMiB: 100, residentMiB: 200,
                cpuPercent: now > previous.time ? (cpu - previous.cpu) / (now - previous.time) * 100 : 0))
            previous = (now, cpu)
        }
        observe()
        while diagnostics.report.samples.count < 5 {
            Thread.sleep(forTimeInterval: 0.03)
            observe()
            let burst = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - burst < 0.01 {}
            observe()
        }
        let samples = diagnostics.report.samples
        let first = try XCTUnwrap(samples.first), last = try XCTUnwrap(samples.last)
        let span = (last.elapsedSeconds - first.elapsedSeconds) / scale
        let kernel = try XCTUnwrap(kernelAt[last.elapsedSeconds]) - XCTUnwrap(kernelAt[first.elapsedSeconds])
        let reported = keptCPUSeconds(samples) / scale
        XCTAssertGreaterThan(kernel / span, 0.05, "The bursts should keep the process measurably busy")
        XCTAssertEqual(reported, kernel, accuracy: kernel * 0.03, "Kept samples reported \(reported) CPU seconds over \(span) s; the kernel counted \(kernel)")
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
    func testExportSchemaContainsOnlyApprovedMetrics() throws {
        var diagnostics = PerformanceDiagnostics()
        diagnostics.observe(sample(0))
        diagnostics.mark(.launch, at: 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnostics.export()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["build", "schemaVersion", "sampleIntervalSeconds", "sampleCapacity", "eventCapacity", "jobCapacity", "startup", "current", "sampledPeakFootprintMiB", "samples", "events", "jobs", "dictationLatency", "inferenceLatency"]))
        let current = try XCTUnwrap(json["current"] as? [String: Any])
        XCTAssertEqual(Set(current.keys), Set(["elapsedSeconds", "footprintMiB", "residentMiB", "cpuPercent", "droppedAudioSeconds", "bufferedAudioSeconds", "queuedAudioSeconds", "loadedHistoryRows", "modelsReady", "ambientEnabled", "dictationActive", "inferenceRunning"]))
        XCTAssertNil(LatencySummary([]).medianSeconds)
        XCTAssertEqual(LatencySummary([1, 2, 3, 4]).medianSeconds, 2.5)
    }
}
