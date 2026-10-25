import SwiftUI
import Charts
import AppKit
import JotCore

/// Current values observe only the existing readout, while trends own their slower refresh.
struct ActivityLiveImpact: View {
    let service: SpeechService
    let width: CGFloat
    var body: some View {
        JotCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Label("Live on this Mac", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer(minLength: 8)
                    Text("Latest").font(.caption.weight(.medium)).foregroundStyle(.tint)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .modifier(AccentFill(strength: JotTheme.Tint.wash, shape: Capsule()))
                }
                ResourceReadoutView(readout: service.resourceReadout) { resources in
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: ActivityStatColumns.make(width: width - 36, minimum: 130, itemCount: 5), alignment: .leading, spacing: 16) {
                            ActivityStat(title: "Memory footprint", value: resources.valid ? String(format: "%.0f MiB", resources.physicalFootprintMiB) : "—", symbol: "memorychip")
                            ActivityStat(title: "Queued audio", value: String(format: "%.1f s", service.transcriber.queuedSeconds), symbol: "waveform")
                            ActivityStat(title: "Last inference", value: String(format: "%.2f s", service.transcriber.lastInferenceSeconds), symbol: "timer")
                            ActivityStat(title: "Transcript lag", value: String(format: "%.2f s", service.transcriber.lagSeconds), symbol: "clock")
                            ActivityStat(title: "Dropped audio", value: String(format: "%.1f s", service.droppedSeconds), symbol: "waveform.slash")
                        }.accessibilityElement(children: .contain)
                            .accessibilityIdentifier("activity-live-stats")
                        Divider()
                        LazyVGrid(columns: ActivityStatColumns.make(width: width - 36, minimum: 145, itemCount: 3), alignment: .leading, spacing: 12) {
                            ActivityStat(title: "Jot CPU", value: resources.cpuText, symbol: "cpu")
                            ActivityStat(title: "Resident memory", value: resources.valid ? String(format: "%.0f MiB", resources.residentMiB) : "—", symbol: "square.stack.3d.up")
                            ActivityStat(title: "Mac thermal state", value: resources.valid ? resources.thermalState.capitalized : "—", symbol: "thermometer.medium")
                        }
                    }
                }
                ActivityResourceTrends(service: service, wide: width >= 700)
            }
        }
    }
}

private enum ActivityStatColumns {
    static func make(width: CGFloat, minimum: CGFloat, itemCount: Int) -> [GridItem] {
        let spacing: CGFloat = 16
        let count = min(itemCount, max(1, Int((max(0, width) + spacing) / (minimum + spacing))))
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .leading), count: count)
    }
}

struct ActivityTrendPoint: Identifiable {
    let sample: PerformanceSample
    let minutesBeforeLatest: Double
    let segment: Int
    let isolated: Bool
    var id: Double { sample.elapsedSeconds }
}

/// A numeric projection of existing diagnostics: no new sampler, no stored history.
struct ActivityTrendSnapshot {
    let points: [ActivityTrendPoint]
    let spanMinutes: Double

    init(report: PerformanceReport) {
        let latest = report.current?.elapsedSeconds ?? report.samples.last?.elapsedSeconds ?? 0
        let lower = max(0, latest - 900)
        let retained = report.samples.filter {
            $0.elapsedSeconds >= lower && $0.elapsedSeconds <= latest &&
            [$0.elapsedSeconds, $0.cpuPercent, $0.footprintMiB, $0.residentMiB].allSatisfy { $0.isFinite && $0 >= 0 }
        }
        var runs: [(PerformanceSample, Int)] = []
        var segment = 0
        for sample in retained {
            if let previous = runs.last, sample.elapsedSeconds - previous.0.elapsedSeconds > max(75, report.sampleIntervalSeconds * 2.5) { segment += 1 }
            runs.append((sample, segment))
        }
        let counts = Dictionary(grouping: runs, by: { $0.1 }).mapValues(\.count)
        points = runs.map {
            ActivityTrendPoint(sample: $0.0, minutesBeforeLatest: ($0.0.elapsedSeconds - latest) / 60,
                               segment: $0.1, isolated: counts[$0.1] == 1)
        }
        spanMinutes = max(1, min(15, latest / 60))
    }
}

private struct ActivityResourceTrends: View {
    let service: SpeechService
    let wide: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: ActivityTrendSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 2 : 1), spacing: 16) {
                ActivityResourceChart(snapshot: snapshot, metric: .cpu)
                ActivityResourceChart(snapshot: snapshot, metric: .memory)
            }
            Text("Recent minute-spaced measurements from this launch, up to 15 minutes before the latest reading. Gaps stay open. Battery use is not measured.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                snapshot = ActivityTrendSnapshot(report: service.diagnostics.report)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

private struct ActivityResourceChart: View {
    @Environment(\.jotAccent) private var accent
    enum Metric { case cpu, memory }
    let snapshot: ActivityTrendSnapshot?
    let metric: Metric
    private var identifier: String { metric == .cpu ? "activity-cpu-trend" : "activity-memory-trend" }
    private var title: String { metric == .cpu ? "CPU · % of one core" : "Memory · MiB" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if metric == .memory {
                    Spacer(minLength: 4)
                    legend("Footprint", color: accent, dashed: false)
                    legend("Resident", color: .secondary, dashed: true)
                }
            }
            if let snapshot, !snapshot.points.isEmpty {
                Chart(snapshot.points) { point in
                    LineMark(x: .value("Minutes before latest reading", point.minutesBeforeLatest),
                             y: .value(metric == .cpu ? "CPU percent" : "Footprint MiB", metric == .cpu ? point.sample.cpuPercent : point.sample.footprintMiB),
                             series: .value("Series", "primary-\(point.segment)"))
                        .foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                    if metric == .memory {
                        LineMark(x: .value("Minutes before latest reading", point.minutesBeforeLatest), y: .value("Resident MiB", point.sample.residentMiB),
                                 series: .value("Series", "resident-\(point.segment)"))
                            .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    if point.isolated {
                        PointMark(x: .value("Minutes before latest reading", point.minutesBeforeLatest),
                                  y: .value(metric == .cpu ? "CPU percent" : "Footprint MiB", metric == .cpu ? point.sample.cpuPercent : point.sample.footprintMiB))
                            .foregroundStyle(accent).symbolSize(22)
                        if metric == .memory {
                            PointMark(x: .value("Minutes before latest reading", point.minutesBeforeLatest), y: .value("Resident MiB", point.sample.residentMiB))
                                .foregroundStyle(Color.secondary).symbolSize(22)
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: -snapshot.spanMinutes...0)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let minutes = value.as(Double.self) {
                                Text(minutes == 0 ? "Latest" : "\(Int(abs(minutes).rounded()))m earlier")
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 125)
                .accessibilityLabel(metric == .cpu ? "Recent Jot CPU measurements" : "Recent Jot memory measurements")
                .accessibilityIdentifier(identifier)
                if snapshot.points.count == 1 {
                    Text("One measurement so far; a line appears as readings accumulate.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Collecting measurements…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: dashed ? 8 : 12, height: 2).accessibilityHidden(true)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
