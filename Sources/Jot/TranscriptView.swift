import SwiftUI
import AppKit
import JotCore

/// The latest service notice at the bottom right of the content pane; it fades after six seconds unless a new one replaces it.
private struct NoticeToast: View {
    let notice: String
    @State private var visible = false
    private static let successWords = ["finished", "cleared", "deleted", "regrouped", "saved", "copied", "connected again"]
    private static let failureWords = ["fail", "could not", "error", "interrupted"]
    /// Green for a notice that reports something done, orange for everything else.
    private var success: Bool {
        let lower = notice.lowercased()
        return Self.successWords.contains { lower.contains($0) } && !Self.failureWords.contains { lower.contains($0) }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(success ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(notice).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .modifier(GlassSurface(radius: 12))
        .frame(maxWidth: 440, alignment: .trailing)
        .opacity(visible && !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!visible)
        .task(id: notice) {
            guard !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { visible = false; return }
            withAnimation(.easeOut(duration: 0.2)) { visible = true }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { visible = false }
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var service: SpeechService
    let delegate: JotDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var copiedID: String?
    @State private var showHistory = true
    @AppStorage(JotDefaultsKey.historyTextView) private var historyTextView = true
    @State private var search = ""
    @State private var section = Section.live
    @State private var copyReset: Task<Void, Never>?

    private enum Section: String, CaseIterable {
        case live = "Live", dictations = "Dictations", sessions = "Sessions", people = "People", general = "General", vocabulary = "Vocabulary", models = "Models & updates", activity = "Activity"
        /// The four under the Settings heading, drawn quieter than the places where transcripts live.
        var isSetting: Bool { self == .general || self == .vocabulary || self == .models || self == .activity }
        /// Help for the page as a whole, behind the (i) beside its title.
        var info: String? {
            switch self {
            case .people: "Jot recognizes these voices in new sessions. Delete a person and their voice is forgotten."
            case .vocabulary: "Your spellings, every time you dictate. Original transcripts stay unchanged."
            default: nil
            }
        }
        var symbol: String {
            switch self {
            case .live: "dot.radiowaves.left.and.right"
            case .dictations: "text.alignleft"
            case .sessions: "rectangle.stack"
            case .people: "person.2"
            case .vocabulary: "character.book.closed"
            case .activity: "chart.xyaxis.line"
            case .general: "gearshape"
            case .models: "square.stack.3d.up"
            }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        JotBrand().padding(.horizontal, 8)
                        ServiceControls(service: service)
                            .padding(18).modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.04)))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Section.allCases.filter { !$0.isSetting }, id: \.self) { item in navigationRow(item) }
                            Text("Settings").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                .padding(.horizontal, 12).padding(.top, 10)
                            ForEach(Section.allCases.filter(\.isSetting), id: \.self) { item in navigationRow(item) }
                        }
                    }.padding(.bottom, 8)
                }
                // Glass inside a scroll view still draws above the title bar unless the scroll view clips it.
                .clipped()
                ResourceReadoutView(readout: service.resourceReadout) { resources in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CPU").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", resources.processCPUPercent)).monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Memory").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.0f MB", resources.residentMiB)).monospacedDigit()
                        }
                    }
                }.padding(.horizontal, 8)
            }.padding(8).frame(width: 282)
            VStack(alignment: .leading, spacing: 18) {
                // Live draws its own title row so the recording chips sit beside it.
                if section != .live { titleRow }
                switch section {
                case .live: LiveView(service: service)
                case .dictations: dictations
                case .sessions: SessionsView(service: service, openLive: { section = .live })
                case .people: PeopleView(service: service)
                case .vocabulary: VocabularyView(service: service)
                case .activity: activity
                case .general: general
                case .models: models
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(GlassSurface())
                .overlay(alignment: .bottomTrailing) { NoticeToast(notice: service.notice).padding(20) }
        }
        .padding(16)
        .background(JotBackdrop())
        .tint(Color(nsColor: .controlAccentColor))
        .background(WindowAttachment(attach: delegate.attach))
        .onAppear { delegate.openAction = { openWindow(id: "main") } }
        .onDisappear { copyReset?.cancel() }
        .onChange(of: service.historyRevision) { _, _ in copiedID = nil }
        // Capture starting is the one moment Live is opened for the user; after that the choice is theirs.
        .onChange(of: service.ambientEnabled) { _, on in if on { section = .live } }
    }

    private var titleRow: some View {
        HStack {
            Text(section.rawValue).font(.system(size: 26, weight: .bold, design: .rounded))
            if let info = section.info { InfoButton(title: section.rawValue, detail: info) }
            Spacer()
            if section == .dictations {
                Button("Open Dictations in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([JotPaths.directory.appendingPathComponent("transcripts.sqlite3")])
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Open Dictations in Finder")
                .modifier(GlassButton())
                .help("Shows the transcript database. Quit Jot before moving its files to Trash.")
                Button("Clear", systemImage: "clear", role: .destructive) {
                    do { try service.clearHistory(); search = ""; copiedID = nil }
                    catch { service.notice = error.localizedDescription }
                }.modifier(GlassButton()).help("Delete every saved dictation. Sessions are deleted from the Sessions tab.")
                Button(showHistory ? "Hide" : "Show", systemImage: showHistory ? "eye.slash" : "eye") { showHistory.toggle() }
                    .modifier(GlassButton())
            }
        }
    }
    private func navigationRow(_ item: Section) -> some View {
        Button { section = item } label: {
            HStack(spacing: 8) {
                Label(item.rawValue, systemImage: item.symbol)
                    .font(item.isSetting ? .callout.weight(section == item ? .semibold : .regular) : .body.weight(section == item ? .semibold : .regular))
                    .foregroundStyle(item.isSetting && section != item ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if item == .live && service.ambientEnabled { Circle().fill(.red).frame(width: 8, height: 8).accessibilityLabel("Recording") }
                if let count = count(item) { countPill(count) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, item.isSetting ? 8 : 12)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .modifier(NavigationSurface(selected: section == item))
        }.buttonStyle(.plain)
    }
    private func count(_ item: Section) -> Int? {
        switch item {
        case .dictations: service.dictationCount
        case .sessions: service.sessions.count
        default: nil
        }
    }
    private func countPill(_ count: Int) -> some View {
        Text(count, format: .number).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var dictations: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search dictations", text: $search)
                .textFieldStyle(.roundedBorder)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: search) { _, value in service.searchHistory(value) }
            if showHistory {
                HStack {
                    Picker("Dictations view", selection: $historyTextView) {
                        Text("Text").tag(true)
                        Text("Cards").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        .accessibilityLabel("Dictations view")
                    if historyTextView {
                        InfoButton(title: "Text view", detail: "Oldest to newest. Drag to highlight, then ⌘C. ⌘A selects all loaded text. New updates wait while text is selected.")
                    }
                }
            }
            if !showHistory {
                empty("Dictations hidden", symbol: "eye.slash")
            } else if service.history.isEmpty {
                empty(search.isEmpty ? "No dictations yet" : "No matches", symbol: "text.alignleft")
            } else if historyTextView {
                SelectableHistory(transcripts: service.history, search: search)
                    .id(service.historyRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if service.hasMoreHistory {
                    HStack {
                        Spacer()
                        Button("Load more") { service.loadMoreHistory() }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(service.history) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { copy(item) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(TranscriptExport.historyName(item)).font(.caption.weight(.medium))
                                            Spacer()
                                            Text(item.startedAt.addingTimeInterval(item.startSeconds), format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc").foregroundStyle(copiedID == item.id ? .green : .secondary)
                                        }
                                        Text(item.text).font(.body).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(copiedID == item.id ? "Copied" : "Copy transcript")
                                    .accessibilityLabel("Copy \(item.mode) transcript")
                                    .accessibilityValue(copiedID == item.id ? "Copied" : item.text)
                                HStack {
                                    Spacer()
                                    Button("Delete transcript", systemImage: "trash", role: .destructive) {
                                        do { try service.deleteHistoryCard(item) }
                                        catch { service.notice = error.localizedDescription }
                                    }.labelStyle(.iconOnly).buttonStyle(.plain).help("Delete this transcript")
                                }
                            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                        }
                        if service.hasMoreHistory {
                            Button("Load more") { service.loadMoreHistory() }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func copy(_ item: Transcript) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(item.text, forType: .string) else { service.notice = "Could not copy transcript."; return }
        copiedID = item.id
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copiedID = nil }
        }
    }
    private func empty(_ title: String, symbol: String) -> some View {
        VStack(spacing: 12) { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary); Text(title).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
