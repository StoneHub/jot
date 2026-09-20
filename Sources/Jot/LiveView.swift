import SwiftUI
import AppKit
import JotCore

/// The session being recorded, oldest row at the top and the newest at the bottom. Idle, it shows the tail of the last session with the same start controls.
struct LiveView: View {
    @ObservedObject var service: SpeechService
    @State private var rows: [Transcript] = []
    @State private var labelTarget: Transcript?
    @State private var labelDraft = ""
    @State private var naming = false
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var working = false
    /// True while the feed is scrolled to its end; new rows then keep the end in view, a reader who scrolled up is left alone.
    @State private var pinned = true
    /// Set by Clear: lines up to this moment stay in the session but are hidden here.
    @State private var clearedThrough: Date?

    private var running: Bool { service.ambientEnabled }
    /// The recording session, or the newest saved one while idle.
    private var shownID: String? { running || service.meetingTitle != nil ? service.activeSessionID : service.sessions.first?.sessionID }
    private var speakerCount: Int { Set(rows.compactMap(\.speakerID).filter { $0 != "overlap" }).count }
    private var recognized: [String] {
        var names: [String] = []
        for name in rows.compactMap(\.speakerLabel) where !name.isEmpty && !names.contains(name) { names.append(name) }
        return names
    }
    /// Follow text replacements too, including equal-length edits and changes above the last row.
    private var feedKey: [String] { shown.flatMap { [$0.id, $0.text] } }
    private var shown: [Transcript] {
        guard let clearedThrough else { return rows }
        return rows.filter { $0.startedAt.addingTimeInterval($0.startSeconds) > clearedThrough }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if running || service.meetingTitle != nil {
                if shown.isEmpty && clearedThrough != nil {
                    Text("Cleared. New lines appear here.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    feed(shown)
                }
            } else {
                Text("Not listening").font(.callout).foregroundStyle(.secondary)
                if !shown.isEmpty {
                    Text("Last session").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    feed(Array(shown.suffix(5)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onChange(of: service.activeSessionID) { _, _ in clearedThrough = nil; refresh() }
        .onChange(of: service.ambientEnabled) { _, _ in refresh() }
        .onChange(of: service.sessions.map(\.transcriptCount)) { _, _ in refresh() }
        .onChange(of: service.transcriptRevision) { _, _ in refresh() }
        .onChange(of: service.historyRevision) { _, _ in labelTarget = nil; refresh() }
        .sheet(item: $labelTarget) { target in
            SpeakerNameSheet(transcript: target, service: service, draft: $labelDraft,
                onSave: { refresh(); labelTarget = nil },
                onCancel: { labelTarget = nil })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Live").font(.system(size: 26, weight: .bold, design: .rounded))
            if let title = service.meetingTitle, !running {
                chip("\(title) · Paused")
            } else if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    chip("\(service.meetingTitle ?? "Listening") · \(Self.elapsed(since: service.sessionStarted, at: context.date))", color: .red, dot: true)
                }
                if speakerCount > 0 { chip("\(speakerCount) speaker\(speakerCount == 1 ? "" : "s")") }
                if !recognized.isEmpty { chip("recognized \(recognized.joined(separator: ", "))", color: .green, dot: true) }
            }
            Spacer()
            clearButton
            tools
        }
    }

    /// Clear hides what is on screen. Sessions keeps every line, so nothing is deleted here.
    @ViewBuilder private var clearButton: some View {
        if clearedThrough != nil {
            Button("Show all") { clearedThrough = nil }.modifier(GlassButton())
                .help("Show the lines Clear hid.").accessibilityIdentifier("live-show-all")
        } else if !shown.isEmpty && !renaming && !naming {
            Button("Clear") { clearedThrough = shown.last.map { $0.startedAt.addingTimeInterval($0.startSeconds) } }
                .modifier(GlassButton())
                .help("Hide what is on screen. Sessions keeps every line.").accessibilityIdentifier("live-clear")
        }
    }

    @ViewBuilder private var tools: some View {
        if renaming {
            TextField("Meeting name", text: $titleDraft).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(commitRename)
            Button("Save", action: commitRename).modifier(PrimaryGlassButton()).disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { renaming = false }.modifier(GlassButton())
        } else if service.meetingTitle != nil {
            Button("Rename") { titleDraft = service.meetingTitle ?? ""; renaming = true }.modifier(GlassButton())
            Button(working ? "Saving…" : "End meeting") {
                working = true
                Task { await service.endMeeting(); working = false }
            }.modifier(PrimaryGlassButton()).tint(.red).disabled(working).accessibilityIdentifier("live-end-meeting")
        } else if running {
            Button("Pause") { service.pause() }.modifier(GlassButton()).accessibilityIdentifier("live-stop")
        } else if naming {
            TextField("Meeting name", text: $titleDraft).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(startMeeting)
            Button("Start", action: startMeeting).modifier(PrimaryGlassButton())
                .disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty || working)
            Button("Cancel") { naming = false; titleDraft = "" }.modifier(GlassButton())
        } else {
            Button("Start meeting") { titleDraft = ""; naming = true }.modifier(PrimaryGlassButton()).accessibilityIdentifier("live-start-meeting")
            Button("Resume") { service.prepare() }.modifier(PrimaryGlassButton()).disabled(service.isTransitioning)
        }
    }

    private func feed(_ rows: [Transcript]) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in line(row).id(row.id) }
                    }
                    .frame(maxWidth: 820, alignment: .leading).padding(.vertical, 4)
                    .background(GeometryReader { content in
                        Color.clear.preference(key: FeedEndKey.self, value: content.frame(in: .named("feed")).maxY)
                    })
                }
                .coordinateSpace(name: "feed")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(FeedEndKey.self) { end in pinned = end <= viewport.size.height + 48 }
                .onChange(of: feedKey) { _, _ in if pinned, let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func line(_ row: Transcript) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                speakerChip(row)
                Text(row.startedAt.addingTimeInterval(row.startSeconds), format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.frame(width: 150, alignment: .leading)
            Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Solid for a named speaker, dashed in the accent color for one still waiting on a name; both open the naming sheet.
    @ViewBuilder private func speakerChip(_ row: Transcript) -> some View {
        if let speaker = row.speakerID, speaker != "overlap" {
            let named = !(row.speakerLabel ?? "").isEmpty
            Button { labelDraft = row.speakerLabel ?? ""; labelTarget = row } label: {
                Text(named ? TranscriptExport.speakerName(row) : "\(TranscriptExport.speakerName(row)) · name?")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .foregroundStyle(named ? Color.primary : Color(nsColor: .controlAccentColor))
                    .background(named ? Color.primary.opacity(0.08) : Color(nsColor: .controlAccentColor).opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .controlAccentColor).opacity(named ? 0 : 0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }.buttonStyle(.plain).help(named ? "Rename this speaker" : "Name this speaker")
        } else {
            Text(TranscriptExport.speakerName(row)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ text: String, color: Color? = nil, dot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(color ?? .secondary).frame(width: 7, height: 7) }
            Text(text).font(.caption.weight(.medium).monospacedDigit()).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .foregroundStyle(color ?? Color.primary)
        .background((color ?? Color.primary).opacity(color == nil ? 0.08 : 0.16), in: Capsule())
    }

    private func refresh() { rows = shownID.map(service.sessionParagraphs) ?? [] }
    private func commitRename() {
        service.renameMeeting(titleDraft); renaming = false
    }
    private func startMeeting() {
        let title = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        working = true
        Task { await service.startMeeting(title); working = false; naming = false; titleDraft = "" }
    }

    static func elapsed(since start: Date, at now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct FeedEndKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
