import SwiftUI
import AppKit
import JotCore

/// One sheet names a speaker from Live or Sessions; the label is scoped to the row's session.
struct SpeakerNameSheet: View {
    let transcript: Transcript
    let service: SpeechService
    @Binding var draft: String
    let onSave: () -> Void
    let onCancel: () -> Void
    /// The pass's embedding for this speaker, when it has run; the toggle is offered only then.
    @State private var voice: [Float]?
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this speaker for this session").font(.headline)
            TextField("Name", text: $draft).textFieldStyle(.roundedBorder).frame(width: 280)
            if voice != nil { Toggle("Remember this voice", isOn: $remember).toggleStyle(.checkbox) }
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    if let speaker = transcript.speakerID { service.labelSpeaker(session: transcript.sessionID, speaker: speaker, name: draft, voice: remember ? voice : nil) }
                    onSave()
                }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20)
        .onAppear { voice = transcript.speakerID.flatMap { service.passEmbedding(session: transcript.sessionID, speaker: $0) } }
    }
}

/// Every capture session, readable whole at full width; the picker keeps the list out of the reading column.
struct SessionsView: View {
    @ObservedObject var service: SpeechService
    /// Picking the recording session opens Live instead of reading it here.
    let openLive: () -> Void
    @State private var selectedID: String?
    @State private var rows: [Transcript] = []
    @State private var search = ""
    @State private var hits: [Transcript] = []
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var labelTarget: Transcript?
    @State private var labelDraft = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.sessions.isEmpty {
                Text("No sessions yet. Resume Jot to start listening.").foregroundStyle(.secondary)
            } else {
                header
                TextField("Search sessions", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    .onChange(of: search) { _, value in hits = service.searchSessions(value) }
                if !search.isEmpty {
                    searchResults
                } else if let session = selected {
                    Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.transcriptCount) segments · \(TranscriptExport.clock(session.durationSeconds)) · Click a speaker to name them")
                        .font(.caption).foregroundStyle(.secondary)
                    transcript
                }
            }
        }
        .onAppear { service.refreshSessions(); if selectedID == nil { select(readable.first?.sessionID) } }
        .onChange(of: service.historyRevision) { _, _ in
            labelTarget = nil
            select(readable.contains { $0.sessionID == selectedID } ? selectedID : readable.first?.sessionID)
            if !search.isEmpty { hits = service.searchSessions(search) }
        }
        .onChange(of: revisionAndCounts) { old, new in
            // A pass or Regroup moves the revision and the counts together, and the revision's handler above reads the session. This one reads only for rows saved without a revision.
            guard old.first == new.first, let selectedID else { return }
            rows = service.sessionParagraphs(selectedID)
        }
        .sheet(item: $labelTarget) { target in
            SpeakerNameSheet(transcript: target, service: service, draft: $labelDraft,
                onSave: { rows = service.sessionParagraphs(target.sessionID); labelTarget = nil },
                onCancel: { labelTarget = nil })
        }
    }

    private var selected: TranscriptSession? { service.sessions.first { $0.sessionID == selectedID } }
    /// The history revision, then each session's row count.
    private var revisionAndCounts: [Int] { [service.historyRevision] + service.sessions.map(\.transcriptCount) }
    private func isRecording(_ session: TranscriptSession) -> Bool { session.sessionID == service.activeSessionID && service.ambientEnabled }
    /// Saved sessions this reader can show; the recording one belongs to Live.
    private var readable: [TranscriptSession] { service.sessions.filter { !isRecording($0) } }
    /// The recording session first, then the saved ones newest first.
    private var ordered: [TranscriptSession] { service.sessions.filter(isRecording) + readable }

    private func label(_ session: TranscriptSession) -> String {
        "\(session.title ?? "Untitled session") · \(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TranscriptExport.clock(session.durationSeconds))"
    }

    /// One row: which session, rename, copy, export. The session menu scales past the few sessions a list column shows well.
    private var header: some View {
        HStack(spacing: 8) {
            if renaming, let session = selected {
                TextField("Session name", text: $titleDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    .onSubmit { commitRename(session) }
                Button("Save") { commitRename(session) }.modifier(PrimaryGlassButton())
                Button("Cancel") { renaming = false }.modifier(GlassButton())
            } else {
                Picker("Session", selection: Binding(get: { selectedID ?? "" }, set: { select($0) })) {
                    ForEach(ordered) { session in
                        if isRecording(session) { (Text("● ").foregroundStyle(.red) + Text(label(session))).tag(session.sessionID) }
                        else { Text(label(session)).tag(session.sessionID) }
                    }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 480)
                if let session = selected {
                    Button("Rename", systemImage: "pencil") { titleDraft = session.title ?? ""; renaming = true }
                        .labelStyle(.iconOnly).modifier(GlassButton()).help("Rename this session")
                }
            }
            Spacer()
            if let session = selected {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copyAll(session) }.modifier(GlassButton())
                Button("Regroup", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        do { try await service.regroupSession(session.sessionID) }
                        catch { service.notice = error.localizedDescription }
                    }
                }.modifier(GlassButton()).help("Relabels this session's speakers from its speaker pass, or from the speaker settings in General when it has none")
                Button("Export", systemImage: "square.and.arrow.up") {
                    do { NSWorkspace.shared.activateFileViewerSelecting([try service.exportSession(session.sessionID)]) }
                    catch { service.notice = error.localizedDescription }
                }.modifier(PrimaryGlassButton()).help("Saves Markdown to Documents/Jot Sessions and shows it in Finder")
                Button("Delete session", systemImage: "trash", role: .destructive) {
                    do { try service.deleteSession(session.sessionID) }
                    catch { service.notice = error.localizedDescription }
                }.labelStyle(.iconOnly).modifier(GlassButton())
                    .disabled(!service.canDeleteSession(session.sessionID))
                    .help("Delete this saved session")
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TranscriptExport.clock(row.startSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 56, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            if row.speakerID != nil && row.speakerID != "overlap" {
                                Button(TranscriptExport.speakerName(row)) { labelDraft = row.speakerLabel ?? ""; labelTarget = row }
                                    .buttonStyle(.link).font(.caption.weight(.semibold))
                            } else {
                                Text(TranscriptExport.speakerName(row)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.frame(maxWidth: 820, alignment: .leading).padding(.vertical, 4)
        }
    }

    /// Matching rows from every session; a click opens that session in the reader.
    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if hits.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                ForEach(hits) { hit in
                    Button { select(hit.sessionID); search = "" } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(service.sessions.first { $0.sessionID == hit.sessionID }?.title ?? "Untitled session") · \(hit.startedAt.addingTimeInterval(hit.startSeconds).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(hit.text).lineLimit(3).multilineTextAlignment(.leading).foregroundStyle(.primary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                        .help("Open this session")
                }
            }.frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func select(_ id: String?) {
        if let id, id == service.activeSessionID, service.ambientEnabled { openLive(); return }
        selectedID = id; renaming = false
        rows = id.map { service.sessionParagraphs($0) } ?? []
    }
    private func commitRename(_ session: TranscriptSession) {
        service.renameSession(session.sessionID, title: titleDraft); renaming = false
    }
    private func copyAll(_ session: TranscriptSession) {
        let text = rows.map { "[\(TranscriptExport.clock($0.startSeconds))] \(TranscriptExport.speakerName($0)): \($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { service.notice = "Could not copy session."; return }
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }
}
