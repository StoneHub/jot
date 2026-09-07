#if DEBUG
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class FeedbackSession: ObservableObject {
    @Published var picking = false
    @Published var draft: FeedbackRecord?
    @Published var note = ""
    @Published var acceptance = ""
    @Published var records: [FeedbackRecord] = []
    @Published var selected: Set<UUID> = []
    @Published var error: String?
    @Published var message: String?
    @Published var preview = false
    private let appID: String
    private var screen: String
    private var history: FeedbackHistory?
    private var panel: NSPanel?

    init(appID: String, screen: String) {
        self.appID = appID
        self.screen = screen
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            // Hex encoding keeps arbitrary app and screen identifiers from becoming path traversal.
            let key = Data(appID.utf8).map { String(format: "%02x", $0) }.joined()
            let url = root.appendingPathComponent("DevFeedback", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true).appendingPathComponent("history.json")
            history = try FeedbackHistory(url: url)
            records = history?.records ?? []
        } catch { self.error = "Could not load feedback history: \(error.localizedDescription)" }
    }

    func updateScreen(_ screen: String) {
        self.screen = screen
        panel?.title = "UI Feedback · \(screen)"
    }

    var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        return draft.note != note || draft.acceptance != acceptance || !records.contains(where: { $0.id == draft.id })
    }

    func showPanel() {
        do {
            try history?.reload()
            records = history?.records ?? []
            selected.formIntersection(Set(records.map(\.id)))
        } catch { self.error = "Could not reload feedback history: \(error.localizedDescription)" }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 690),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "UI Feedback · \(screen)"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: FeedbackPanel(session: self))
            window.minSize = NSSize(width: 460, height: 560)
            if let visible = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.maxX - 540, y: visible.midY - 345))
            }
            panel = window
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func startPicking() {
        guard !hasUnsavedChanges else { return }
        discard()
        picking = true
        panel?.orderOut(nil)
    }

    func capture(_ target: FeedbackTarget, bounds: CGRect, appearance: String) {
        guard !hasUnsavedChanges else { return }
        draft = FeedbackRecord(id: UUID(), createdAt: Date(), appID: appID, screen: screen,
                               target: target, bounds: FeedbackBounds(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                               appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                               build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                               appearance: appearance, note: "", acceptance: "")
        note = ""; acceptance = ""; picking = false; message = nil
        showPanel()
    }

    func edit(_ record: FeedbackRecord) {
        guard !hasUnsavedChanges else { return }
        draft = record; note = record.note; acceptance = record.acceptance; message = nil
    }

    func discard() { draft = nil; note = ""; acceptance = "" }

    func save(pickNext: Bool) {
        guard var record = draft, let history else { return }
        record.note = note; record.acceptance = acceptance
        do {
            try history.save(record)
            records = history.records
            discard()
            error = nil; message = "Saved locally."
            if pickNext { startPicking() }
        } catch { self.error = error.localizedDescription }
    }

    func deleteSelected() {
        guard let history else { return }
        do {
            try history.delete(ids: selected)
            records = history.records; selected = []; error = nil
        } catch { self.error = error.localizedDescription }
    }

    var selectedRecords: [FeedbackRecord] { records.filter { selected.contains($0.id) } }
    func revealHistory() {
        guard let url = history?.url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else { message = "Save a note first to create the history file." }
    }

    var canSave: Bool { history != nil && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func copyMarkdown() {
        let text = FeedbackHistory.markdown(selectedRecords)
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            message = "Copied \(selectedRecords.count) notes."
        } else { error = "Could not write to the clipboard." }
    }

    func exportJSON() {
        do {
            let data = try FeedbackHistory.json(selectedRecords)
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "swiftui-feedback.json"
            guard let panel else { return }
            savePanel.beginSheetModal(for: panel) { [weak self] response in
                guard response == .OK, let url = savePanel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self?.message = "Exported selected notes."
                } catch { self?.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct FeedbackPanel: View {
    @ObservedObject var session: FeedbackSession
    @State private var confirmDiscard = false
    @State private var confirmDelete = false
    @State private var exportAfterDismiss = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UI Feedback").font(.title2.bold())
                Spacer()
                Button("Pick target") { session.startPicking() }
                    .disabled(session.hasUnsavedChanges)
                    .accessibilityIdentifier("dev-feedback.pick")
            }
            Text("Local notes. Only selected exports leave this app. View text and screenshots are not collected.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message = session.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let draft = session.draft {
                Text(draft.target.label).font(.headline)
                Text("\(draft.target.id) · \(draft.target.file):\(draft.target.line)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Requested change").font(.caption)
                TextEditor(text: $session.note).frame(minHeight: 65, maxHeight: 95)
                    .border(.secondary.opacity(0.3)).accessibilityIdentifier("dev-feedback.note")
                Text("Acceptance checks (optional)").font(.caption)
                TextEditor(text: $session.acceptance).frame(height: 50)
                    .border(.secondary.opacity(0.3)).accessibilityIdentifier("dev-feedback.acceptance")
                HStack {
                    Button("Discard") { confirmDiscard = true }
                    Spacer()
                    Button("Save") { session.save(pickNext: false) }.disabled(!session.canSave)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityIdentifier("dev-feedback.save")
                    Button("Save & pick next") { session.save(pickNext: true) }.disabled(!session.canSave)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
            }
            Divider()
            HStack {
                Text("History (\(session.records.count))").font(.headline)
                Button("Show in Finder") { session.revealHistory() }.font(.caption)
                Spacer()
                Button("Select all") { session.selected = Set(session.records.map(\.id)) }
                Button("Clear") { session.selected = [] }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.records.isEmpty {
                        Text("Pick a target to leave your first note.").foregroundStyle(.secondary).padding(.vertical)
                    }
                    ForEach(session.records) { record in
                        HStack(alignment: .top) {
                            Toggle(isOn: Binding(get: { session.selected.contains(record.id) }, set: { selected in
                                if selected { session.selected.insert(record.id) } else { session.selected.remove(record.id) }
                            })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel("Select \(record.target.label)")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.target.label).font(.subheadline.bold())
                                Text(record.note).font(.callout).lineLimit(3)
                            }
                            Spacer()
                            Button("Edit") { session.edit(record) }.disabled(session.hasUnsavedChanges)
                        }
                        Divider()
                    }
                }
            }.frame(minHeight: 100)
            HStack {
                Button("Delete selected") { confirmDelete = true }.disabled(session.selected.isEmpty || session.hasUnsavedChanges)
                Spacer()
                Button("Review export (\(session.selected.count))") { session.preview = true }
                    .disabled(session.selected.isEmpty)
                    .accessibilityIdentifier("dev-feedback.review")
            }
        }
        .padding(18).frame(minWidth: 430, minHeight: 520)
        .alert("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { session.discard() }
        }
        .alert("Delete \(session.selected.count) selected notes?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { session.deleteSelected() }
        } message: { Text("Previously exported files and clipboard copies will remain.") }
        .sheet(isPresented: $session.preview, onDismiss: {
            if exportAfterDismiss { exportAfterDismiss = false; session.exportJSON() }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review \(session.selected.count) selected notes").font(.headline)
                ScrollView { Text(FeedbackHistory.markdown(session.selectedRecords)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Back") { session.preview = false }
                    Spacer()
                    Button("Copy Markdown") { session.copyMarkdown(); session.preview = false }
                    Button("Export JSON…") { exportAfterDismiss = true; session.preview = false }
                }
            }.padding(20).frame(width: 560, height: 500)
        }
    }
}
#endif
