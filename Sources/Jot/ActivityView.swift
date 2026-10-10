import SwiftUI
import Charts
import AppKit
import JotCore

/// Aggregate reads have their own observation boundary and run only while Activity is visible.
/// Resource sampling never triggers a history query.
@MainActor
final class ActivityInsightsLoader: ObservableObject {
    @Published private(set) var report: ActivityReport?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var request = 0
    private var readSequence = 0
    private var inFlight: (id: Int, days: Int, store: TranscriptStore, operation: StoreOperation<ActivityReport>)?
    private let fixture: Bool

    init(report: ActivityReport? = nil, error: String? = nil) {
        self.report = report
        self.error = error
        fixture = report != nil || error != nil
    }

    func refresh(library: SessionLibrary, days: Int) async {
        guard !fixture else { return }
        request &+= 1
        let identity = request
        if report?.days != days { report = nil }
        loading = true
        error = nil
        defer { if identity == request { loading = false } }
        // A cancelled StoreExecutor read still finishes. Period changes share that read,
        // then only the latest visible request may submit one follow-up for its period.
        while !Task.isCancelled, identity == request {
            guard let store = library.store else {
                error = "Saved history is unavailable. Jot will try again while this page is open."
                return
            }
            if inFlight == nil {
                readSequence &+= 1
                inFlight = (readSequence, days, store,
                            library.storeExecutor.submit { try store.activity(days: days) })
            }
            guard let read = inFlight else { return }
            do {
                let next = try await read.operation.value
                if inFlight?.id == read.id { inFlight = nil }
                guard !Task.isCancelled, identity == request else { return }
                guard read.days == days, read.store === library.store else { continue }
                report = next
                return
            } catch {
                if inFlight?.id == read.id { inFlight = nil }
                guard !Task.isCancelled, identity == request else { return }
                guard read.days == days, read.store === library.store else { continue }
                self.error = "Activity could not refresh. Your saved history is unchanged."
                return
            }
        }
    }
}

struct ActivityView: View {
    @ObservedObject var service: SpeechService
    @ObservedObject var library: SessionLibrary
    @StateObject private var insights: ActivityInsightsLoader
    @Environment(\.scenePhase) private var scenePhase
    @State private var days = 7
    @State private var showAdvanced = false
    @State private var selectedDate: Date?

    /// Fixtures let the owned window checks render this screen without opening private history.
    init(service: SpeechService, library: SessionLibrary, fixture: ActivityReport? = nil, fixtureError: String? = nil) {
        self.service = service
        self.library = library
        _insights = StateObject(wrappedValue: ActivityInsightsLoader(report: fixture, error: fixtureError))
        _days = State(initialValue: fixture?.days ?? 7)
    }

    private struct RefreshIdentity: Equatable { let days: Int; let active: Bool }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) { introduction.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 8); periodPicker }
                    VStack(alignment: .leading, spacing: 12) { introduction; periodPicker }
                }
                if let error = insights.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("activity-error")
                }
                if let report = insights.report {
                    dictationSummary(report)
                    dailyChart(report)
                    speechDetails(report)
                    ambientSummary(report)
                    Text("Based on saved history on this Mac. Deleted history is excluded; today is still in progress.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Updated \(report.generatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                } else if insights.loading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading activity…").foregroundStyle(.secondary) }
                        .accessibilityIdentifier("activity-loading")
                        .padding(.vertical, 24)
                }
                macImpact
                advanced
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .task(id: RefreshIdentity(days: days, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await insights.refresh(library: library, days: days)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: days) { _, _ in selectedDate = nil }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("A little perspective on your dictation.").font(.headline)
            Text("Words, everyday use, and Jot’s impact on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var periodPicker: some View {
        Picker("Activity period", selection: $days) {
            Text("7 days").tag(7)
            Text("30 days").tag(30)
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 170)
        .accessibilityIdentifier("activity-period")
    }

    private func dictationSummary(_ report: ActivityReport) -> some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.dictation.wordCount.formatted())
                        .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.tint)
                    Text("saved dictation words").font(.headline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("activity-dictation-words")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ActivityStat(title: "Active days", value: "\(report.dictation.activeDays) of \(report.days)", symbol: "calendar")
                    ActivityStat(title: "Words / active day", value: report.dictation.activeDays > 0 ? (report.dictation.wordCount / report.dictation.activeDays).formatted() : "—", symbol: "text.alignleft")
                    ActivityStat(title: "Verified insertions", value: report.verifiedDictationDeliveries.formatted(), symbol: "checkmark.rectangle",
                                 detail: "Counts retained delivery records that Jot verified as inserted. Older dictation can have saved words without a retained delivery record.")
                }
            }
        }
    }

    private func dailyChart(_ report: ActivityReport) -> some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Dictation by day", systemImage: "chart.bar.xaxis").font(.headline)
                if report.dictation.wordCount == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Room for your next thought.").font(.title3.weight(.medium))
                        Text("No dictation words saved in these \(report.days) days. Hold your dictation shortcut when you have something to say.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 18).accessibilityIdentifier("activity-empty")
                } else {
                    Chart(report.daily) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Saved dictation words", day.dictation.wordCount))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(3)
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(day.dictation.wordCount.formatted()) saved dictation words")
                        if let selectedDay = selectedDay(in: report), selectedDay.id == day.id {
                            RuleMark(x: .value("Selected day", day.date, unit: .day))
                                .foregroundStyle(.secondary.opacity(0.3))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: report.days == 7 ? 1 : 7)) { _ in
                            AxisValueLabel(format: report.days == 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartXSelection(value: $selectedDate)
                    .frame(height: 170)
                    .accessibilityLabel("Daily saved dictation words")
                    .accessibilityIdentifier("activity-daily-chart")
                    if let selected = selectedDay(in: report) {
                        Text("\(selected.date.formatted(date: .abbreviated, time: .omitted)) · \(selected.dictation.wordCount.formatted()) words")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if let busiest = report.daily.max(by: { $0.dictation.wordCount < $1.dictation.wordCount }) {
                        Text("Most words: \(busiest.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(busiest.dictation.wordCount.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func selectedDay(in report: ActivityReport) -> ActivityDay? {
        guard let selectedDate else { return nil }
        var calendar = Calendar.current
        if let zone = TimeZone(identifier: report.timeZoneIdentifier) { calendar.timeZone = zone }
        return report.daily.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private func speechDetails(_ report: ActivityReport) -> some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Dictation rhythm", systemImage: "waveform").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ActivityStat(title: "Speech windows", value: ActivityFormat.duration(report.dictation.speechWindowSeconds), symbol: "clock")
                    ActivityStat(title: "Words / window min", value: report.dictation.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", symbol: "metronome")
                }
                Text("Timing comes from saved dictation segments and includes pauses. The pace uses only words with timing; it is an estimate, not a continuous speech rate.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ambientSummary(_ report: ActivityReport) -> some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Ambient listening", systemImage: "ear").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ActivityStat(title: "Words heard", value: report.ambient.wordCount.formatted(), symbol: "text.bubble")
                    ActivityStat(title: "Sessions", value: report.ambient.sessionCount.formatted(), symbol: "rectangle.stack")
                    ActivityStat(title: "Speech windows", value: ActivityFormat.duration(report.ambient.speechWindowSeconds), symbol: "clock")
                }
                Text("Ambient history may include other speakers. These totals describe what Jot heard, not your personal speaking time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var macImpact: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("On this Mac", systemImage: "desktopcomputer").font(.headline); Spacer(); Text("Now").font(.caption).foregroundStyle(.secondary) }
                ResourceReadoutView(readout: service.resourceReadout) { resources in
                    if resources.valid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 16) {
                            ActivityStat(title: "Jot CPU", value: String(format: "%.1f%%", resources.processCPUPercent), symbol: "cpu",
                                         detail: "100% represents one CPU core. Jot can use more than 100% across several cores. This is a current sample, not an average for the selected period.")
                            ActivityStat(title: "Resident memory", value: String(format: "%.0f MiB", resources.residentMiB), symbol: "memorychip")
                            ActivityStat(title: "Mac thermal state", value: resources.thermalState.capitalized, symbol: "thermometer.medium")
                        }
                    } else {
                        Text("Waiting for a resource sample…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Live process measurements. Battery use and accelerator placement are not measured.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            if showAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    ResourceReadoutView(readout: service.resourceReadout) { resources in
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 16) {
                            ActivityStat(title: "Memory footprint", value: resources.valid ? String(format: "%.0f MiB", resources.physicalFootprintMiB) : "—", symbol: "memorychip")
                            ActivityStat(title: "Queued audio", value: String(format: "%.1f s", service.transcriber.queuedSeconds), symbol: "waveform")
                            ActivityStat(title: "Last inference", value: String(format: "%.2f s", service.transcriber.lastInferenceSeconds), symbol: "timer")
                            ActivityStat(title: "Transcript lag", value: String(format: "%.2f s", service.transcriber.lagSeconds), symbol: "clock")
                            ActivityStat(title: "Dropped audio", value: String(format: "%.1f s", service.droppedSeconds), symbol: "waveform.slash")
                        }
                    }
                    Divider()
                    Text("Recent capture events").font(.headline)
                    if library.events.isEmpty { Text("No recent events").font(.callout).foregroundStyle(.secondary) }
                    ForEach(library.events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(event.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .combine)
                    }
                }.padding(.top, 14)
            }
        } label: { Label("Advanced diagnostics", systemImage: "slider.horizontal.3").font(.callout) }
        .accessibilityIdentifier("activity-advanced")
    }
}

private struct ActivityCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.03), radius: 16))
    }
}

private struct ActivityStat: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(.tint).accessibilityHidden(true)
                Text(title).foregroundStyle(.secondary)
                if let detail { InfoButton(title: title, detail: detail) }
            }.font(.caption)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

enum ActivityFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}
