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
    @Environment(\.jotAccent) private var accent
    let service: SpeechService
    let library: SessionLibrary
    @StateObject private var insights: ActivityInsightsLoader
    @Environment(\.scenePhase) private var scenePhase
    @State private var days = 7
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
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ActivityLiveImpact(service: service, width: geometry.size.width)
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
                        usage(report, wide: wide)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) { historyScope; Spacer(minLength: 8); updated(report) }
                            VStack(alignment: .leading, spacing: 4) { historyScope; updated(report) }
                        }
                    } else if insights.loading {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading activity…").foregroundStyle(.secondary) }
                            .accessibilityIdentifier("activity-loading")
                            .padding(.vertical, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .task(id: RefreshIdentity(days: days, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await insights.refresh(library: library, days: days)
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        .onChange(of: days) { _, _ in selectedDate = nil }
    }

    private var historyScope: some View {
        Text("Saved on this Mac · deleted history excluded · today in progress")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func updated(_ report: ActivityReport) -> some View {
        Text("Updated \(report.generatedAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption).foregroundStyle(.tertiary).fixedSize()
    }

    @ViewBuilder private func usage(_ report: ActivityReport, wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) { dictationSummary(report); speechDetails(report); counters(report) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) { dailyChart(report); ambientSummary(report) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                dictationSummary(report)
                dailyChart(report)
                speechDetails(report)
                counters(report)
                ambientSummary(report)
            }
        }
    }

    private func counters(_ report: ActivityReport) -> some View {
        ActivityCounters(counters: report.counters) {
            // A failed reset leaves the counts as they were, and the refresh shows them.
            try? await library.resetUsage()
            await insights.refresh(library: library, days: days)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your words, over time").font(.headline)
            Text("Saved dictation and ambient listening, kept distinct.")
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
        JotCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.dictation.wordCount.formatted())
                        .font(JotTheme.Display.stat).monospacedDigit()
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
        JotCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Dictation by day", systemImage: "chart.xyaxis.line").font(.headline)
                if report.dictation.wordCount == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Room for your next thought.").font(.title3.weight(.medium))
                        Text("No dictation words saved in these \(report.days) days. Hold your dictation shortcut when you have something to say.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 18).accessibilityIdentifier("activity-empty")
                } else {
                    Chart(report.daily) { day in
                        AreaMark(x: .value("Day", day.date), y: .value("Saved dictation words", day.dictation.wordCount))
                            .foregroundStyle(LinearGradient(colors: [accent.opacity(0.18), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .accessibilityHidden(true)
                        LineMark(x: .value("Day", day.date), y: .value("Saved dictation words", day.dictation.wordCount))
                            .foregroundStyle(accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                        PointMark(x: .value("Day", day.date), y: .value("Saved dictation words", day.dictation.wordCount))
                            .foregroundStyle(accent).symbolSize(report.days == 7 ? 28 : 14)
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
        JotCard {
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
        JotCard {
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

}


struct ActivityStat: View {
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
