import SwiftUI
import AppKit
import JotCore

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(JotDelegate.self) var delegate
    var body: some Scene {
        Window("Jot", id: "main") {
            TranscriptView(service: delegate.service, delegate: delegate)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 920, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            MenuControls(service: delegate.service, delegate: delegate)
        } label: {
            JotMenuIconLabel(service: delegate.service)
        }.menuBarExtraStyle(.window)
    }
}

private struct JotMenuIconLabel: View {
    @ObservedObject var service: SpeechService

    var body: some View {
        Image(nsImage: service.isPaused ? JotMenuIcon.paused : JotMenuIcon.ready)
            .accessibilityLabel(service.isPaused ? "Jot paused" : "Jot controls")
            .help(service.isPaused ? "Jot is paused — open controls to resume" : "Jot — open speech controls")
    }
}

/// Native template icons let macOS supply contrast against light and dark menu bars.
private enum JotMenuIcon {
    static let ready: NSImage = templateImage(description: "Jot") {
        drawWaveform()
    }

    static let paused: NSImage = templateImage(description: "Jot paused") {
        drawWaveform()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 2.5, y: 2.5))
        context.addLine(to: CGPoint(x: 15.5, y: 15.5))
        context.setBlendMode(.clear)
        context.setLineWidth(5)
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)
        context.setLineWidth(2.25)
        context.move(to: CGPoint(x: 2.5, y: 2.5))
        context.addLine(to: CGPoint(x: 15.5, y: 15.5))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawWaveform() {
        for (index, height) in [5.0, 10, 16, 10, 5].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 1 + Double(index) * 3.4,
                y: (18 - height) / 2, width: 2.5, height: height),
                xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    private static func templateImage(description: String, draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

@MainActor
final class JotDelegate: NSObject, NSApplicationDelegate {
    let service = SpeechService()
    weak var mainWindow: NSWindow?
    var openAction: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Use the bundled artwork directly while Launch Services refreshes its icon cache.
        if let url = Bundle.main.url(forResource: "Jot", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = false
            NSApp.applicationIconImage = icon
        }
        service.launch()
    }
    func attach(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.tabbingMode = .disallowed
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        NSApp.setActivationPolicy(.regular)
    }
    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openAction?()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { service.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct WindowAttachment: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> AttachmentView { AttachmentView(attach: attach) }
    func updateNSView(_ view: AttachmentView, context: Context) {}
    final class AttachmentView: NSView {
        let attach: (NSWindow) -> Void
        init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.attach(window) } }
        }
    }
}

private struct GlassSurface: ViewModifier {
    var tint: Color = .clear
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
private struct GlassStage: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) { content }
        } else { content }
    }
}

private struct JotBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.10), .clear, .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.05), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 500)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct JotBrand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: JotMenuIcon.ready)
                .renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(.white).padding(10)
                .frame(width: compact ? 40 : 48, height: compact ? 40 : 48)
                .background(Color(nsColor: .controlAccentColor).gradient, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.3)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Jot").font(compact ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                Text("Local dictation").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NavigationSurface: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.14), radius: 14))
        } else { content }
    }
}

struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
private struct PrimaryGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

/// Every control row shares one grammar: a 20-point gutter for a symbol or status dot, a title with an optional caption, and the control on the right edge.
private struct ControlRow<Control: View>: View {
    var symbol: String? = nil
    var dot: Color? = nil
    let title: String
    var caption: String? = nil
    var secondary = false
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                else if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                else { Color.clear }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(secondary ? .callout : .body).foregroundStyle(secondary ? .secondary : .primary).lineLimit(1)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            control()
        }.frame(maxWidth: .infinity)
    }
}

private struct ServiceControls: View {
    @ObservedObject var service: SpeechService
    var compact = false
    private var statusTitle: String { service.isPaused ? "Paused" : (service.isTransitioning ? "Starting" : "Ready") }
    private var statusCaption: String {
        if service.isPaused { return service.lifecycle.phase == .pausing ? "Releasing models…" : "Models unloaded" }
        return service.ambientEnabled ? "Ambient transcription on" : "Ambient transcription off"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlRow(dot: service.isPaused ? Color.secondary : .green, title: statusTitle, caption: statusCaption) {
                Button {
                    if service.isPaused { service.prepare() } else { service.pause() }
                } label: {
                    Label(service.isPaused ? "Resume" : "Pause", systemImage: service.isPaused ? "play.fill" : "pause.fill")
                }
                .modifier(PrimaryGlassButton())
                .disabled(service.lifecycle.phase == .pausing)
                .help("Pause stops all speech work and unloads models.")
                .accessibilityIdentifier("service-pause-resume")
            }
            Divider()
            MeetingControls(service: service)
            Divider()
            ControlRow(symbol: "mic", title: "Microphone") {
                Picker("Microphone", selection: Binding(get: { service.selectedInputUID }, set: { service.setInput(uid: $0) })) {
                    Text("System Default (\(service.systemDefaultInputName))").tag("")
                    ForEach(service.inputDevices) { device in Text(device.name).tag(device.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                .disabled(!service.canChangeInput)
            }
            .help(service.canChangeInput ? "Choose the microphone Jot uses. This does not change macOS's default input." : "Pause capture before changing the microphone.")
            ControlRow(symbol: "keyboard", title: "Dictation") {
                Toggle("Dictation", isOn: Binding(get: { service.fnRequested }, set: { enabled in
                    if enabled { Task { await service.enableFn() } } else { service.disableFn() }
                })).labelsHidden().toggleStyle(.switch)
            }.help("Hold \(service.shortcut.displayName) to dictate into the focused text field.")
            ControlRow(title: "Hold to talk", secondary: true) { ShortcutSettings(service: service) }
            ControlRow(symbol: "mic", title: "Ambient transcription") {
                Toggle("Ambient transcription", isOn: Binding(get: { service.ambientEnabled }, set: { enabled in
                    Task { await service.setAmbient(enabled) }
                })).labelsHidden().toggleStyle(.switch).disabled(service.lifecycle.phase != .ready)
            }.help("Continuously transcribe the microphone while the service is running.")
            if service.isPaused && (service.fnRequested || service.ambientRequested) {
                Text("Selected features start when you resume.").font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
            }
            if let pending = service.downloadPrompt {
                Divider()
                ModelDownloadPrompt(service: service, bytes: pending)
            }
            if service.permissionsMissing {
                Divider()
                PermissionBanner(service: service)
            }
        }
    }
}

/// One row to record a named meeting; ending it saves the transcript and shows the file.
private struct MeetingControls: View {
    @ObservedObject var service: SpeechService
    @State private var naming = false
    @State private var draft = ""
    @State private var working = false
    var body: some View {
        if let title = service.meetingTitle {
            ControlRow(dot: .red, title: title, caption: "Recording") {
                Button(working ? "Saving…" : "End") {
                    working = true
                    Task { await service.endMeeting(); working = false }
                }.modifier(PrimaryGlassButton()).disabled(working).accessibilityIdentifier("end-meeting")
            }
        } else if naming {
            VStack(alignment: .leading, spacing: 8) {
                ControlRow(symbol: "record.circle", title: "Meeting", caption: "Name it, then start") { EmptyView() }
                HStack(spacing: 8) {
                    TextField("Meeting name", text: $draft).textFieldStyle(.roundedBorder).onSubmit { start() }
                    Button("Start") { start() }.modifier(PrimaryGlassButton())
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    Button("Cancel") { naming = false; draft = "" }.modifier(GlassButton())
                }.padding(.leading, 30)
            }
        } else {
            ControlRow(symbol: "record.circle", title: "Meeting", caption: "Ambient capture with a name") {
                Button("Start") { naming = true }.modifier(GlassButton()).accessibilityIdentifier("start-meeting")
                    .help("Ending it saves Markdown to Documents/Jot Sessions.")
            }
        }
    }
    private func start() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        working = true
        Task { await service.startMeeting(title); working = false; naming = false; draft = "" }
    }
}

/// Asks before the first model download so the user chooses when to spend the bandwidth.
private struct ModelDownloadPrompt: View {
    @ObservedObject var service: SpeechService
    let bytes: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download speech models?").font(.headline)
            Text("Jot downloads \(ModelCache.formatted(bytes)) once, then transcribes on this Mac without sending audio anywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ModelCache.expected) { model in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).font(.callout)
                        Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ModelCache.formatted(model.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Sizes are approximate and depend on the published model revision.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not now") { service.downloadPrompt = nil }.modifier(GlassButton())
                Spacer()
                Button("Download") { service.prepare(confirmingDownload: true) }.modifier(PrimaryGlassButton())
                    .accessibilityIdentifier("confirm-model-download")
            }
        }
    }
}

/// Stays visible until every permission is granted; the one button does whatever macOS still allows.
private struct PermissionBanner: View {
    @ObservedObject var service: SpeechService
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(service.missingPermissionText).font(.callout)
            Spacer(minLength: 8)
            Button("Fix") { service.fixPermissions() }.modifier(PrimaryGlassButton())
                .accessibilityIdentifier("fix-permissions")
        }
    }
}

struct MenuControls: View {
    @ObservedObject var service: SpeechService
    let delegate: JotDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                JotBrand(compact: true)
                Spacer()
                Button("Open", systemImage: "arrow.up.forward") {
                    delegate.openAction = { openWindow(id: "main") }
                    delegate.showWindow()
                }.modifier(GlassButton())
            }
            ServiceControls(service: service, compact: true)
                .padding(18).modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.04)))
            HStack {
                Text(String(format: "CPU %.1f%% · %.0f MB", service.resources.processCPUPercent, service.resources.residentMiB))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }
        }.padding(18).frame(width: 350)
            .modifier(GlassStage()).background(JotBackdrop()).tint(Color(nsColor: .controlAccentColor))
    }
}


/// Every capture session, readable whole at full width; the picker keeps the list out of the reading column.
private struct SessionsView: View {
    @ObservedObject var service: SpeechService
    @State private var selectedID: String?
    @State private var rows: [Transcript] = []
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var labelTarget: Transcript?
    @State private var labelDraft = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.sessions.isEmpty {
                Text("No sessions yet. Start a meeting or switch on ambient transcription.").foregroundStyle(.secondary)
            } else {
                header
                if let session = selected {
                    Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.transcriptCount) segments · \(TranscriptExport.clock(session.durationSeconds)) · Click a speaker to name them")
                        .font(.caption).foregroundStyle(.secondary)
                    transcript
                }
            }
        }
        .onAppear { service.refreshSessions(); if selectedID == nil { select(service.sessions.first?.sessionID) } }
        .onChange(of: service.historyRevision) { _, _ in
            labelTarget = nil
            select(service.sessions.contains { $0.sessionID == selectedID } ? selectedID : service.sessions.first?.sessionID)
        }
        .onChange(of: service.sessions.map(\.transcriptCount)) { _, _ in if let selectedID { rows = service.sessionParagraphs(selectedID) } }
        .sheet(isPresented: Binding(get: { labelTarget != nil }, set: { if !$0 { labelTarget = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Name this speaker for this session").font(.headline)
                TextField("Name", text: $labelDraft).textFieldStyle(.roundedBorder).frame(width: 280)
                HStack {
                    Button("Cancel") { labelTarget = nil }
                    Spacer()
                    Button("Save") {
                        if let target = labelTarget, let speaker = target.speakerID {
                            service.labelSpeaker(session: target.sessionID, speaker: speaker, name: labelDraft)
                            rows = service.sessionParagraphs(target.sessionID)
                        }
                        labelTarget = nil
                    }.disabled(labelDraft.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
    }

    private var selected: TranscriptSession? { service.sessions.first { $0.sessionID == selectedID } }

    private func label(_ session: TranscriptSession) -> String {
        let recording = session.sessionID == service.activeSessionID && service.meetingTitle != nil ? "● " : ""
        return "\(recording)\(session.title ?? "Untitled session") · \(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TranscriptExport.clock(session.durationSeconds))"
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
                    ForEach(service.sessions) { session in Text(label(session)).tag(session.sessionID) }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 480)
                if let session = selected {
                    Button("Rename", systemImage: "pencil") { titleDraft = session.title ?? ""; renaming = true }
                        .labelStyle(.iconOnly).modifier(GlassButton()).help("Rename this session")
                }
            }
            Spacer()
            if let session = selected {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copyAll(session) }.modifier(GlassButton())
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

    private func select(_ id: String?) {
        selectedID = id; renaming = false
        rows = id.map(service.sessionParagraphs) ?? []
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

struct TranscriptView: View {
    @ObservedObject var service: SpeechService
    let delegate: JotDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var selected: Transcript?
    @State private var label = ""
    @State private var copiedID: String?
    @State private var showHistory = true
    @AppStorage("historyTextView") private var historyTextView = true
    @State private var search = ""
    @State private var section = "History"
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 20) {
                JotBrand().padding(.horizontal, 8)
                ServiceControls(service: service)
                    .padding(18).modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.04)))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["History", "Sessions", "Vocabulary", "Activity", "Tuning", "Models"], id: \.self) { item in
                        Button { section = item } label: {
                            Label(item, systemImage: item == "Sessions" ? "rectangle.stack" : item == "Vocabulary" ? "character.book.closed" : item == "History" ? "text.alignleft" : (item == "Activity" ? "chart.xyaxis.line" : (item == "Tuning" ? "slider.horizontal.3" : "square.stack.3d.up")))
                                .font(.body.weight(section == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                                .modifier(NavigationSurface(selected: section == item))
                        }.buttonStyle(.plain)

                    }
                }
                Spacer()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CPU").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", service.resources.processCPUPercent)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Memory").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f MB", service.resources.residentMiB)).monospacedDigit()
                    }
                }.padding(.horizontal, 8)
            }.padding(8).frame(width: 282)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(section).font(.system(size: 26, weight: .bold, design: .rounded))
                    Spacer()
                    if section == "History" {
                        Button("Open History in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([JotPaths.directory.appendingPathComponent("transcripts.sqlite3")])
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Open History in Finder")
                        .modifier(GlassButton())
                        .help("Shows the transcript database. Quit Jot before moving history files to Trash.")

                        Button("Clear", systemImage: "clear", role: .destructive) {
                            do { try service.clearHistory(); search = ""; selected = nil; copiedID = nil }
                            catch { service.notice = error.localizedDescription }
                        }.modifier(GlassButton()).help("Delete all saved transcripts and sessions")

                        Button(showHistory ? "Hide" : "Show", systemImage: showHistory ? "eye.slash" : "eye") { showHistory.toggle() }
                            .modifier(GlassButton())

                    }
                }
                if !service.notice.isEmpty {
                    Text(service.notice).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if section == "History" { history }
                else if section == "Sessions" { SessionsView(service: service) }
                else if section == "Vocabulary" { VocabularyView(service: service) }
                else if section == "Activity" { activity }
                else if section == "Tuning" { tuning }
                else { models }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(GlassSurface())
        }
        .padding(16)
        .modifier(GlassStage())
        .background(JotBackdrop())
        .tint(Color(nsColor: .controlAccentColor))
        .background(WindowAttachment(attach: delegate.attach))
        .onAppear { delegate.openAction = { openWindow(id: "main") } }
        .onDisappear { copyReset?.cancel() }
        .onChange(of: service.historyRevision) { _, _ in selected = nil; copiedID = nil }

        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name speaker").font(.headline)
                TextField("Name for this session", text: $label)
                HStack {
                    Button("Cancel") { selected = nil }
                    Spacer()
                    Button("Save") {
                        guard let item = selected, let speaker = item.speakerID else { return }
                        service.labelSpeaker(session: item.sessionID, speaker: speaker, name: label)
                        selected = nil
                    }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search transcripts", text: $search)
                .textFieldStyle(.roundedBorder)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: search) { _, value in service.searchHistory(value) }

            if showHistory {
                HStack {
                    Picker("History view", selection: $historyTextView) {
                        Text("Text").tag(true)
                        Text("Cards").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        .accessibilityLabel("History view")

                    if historyTextView {
                        Text("Drag to highlight, then ⌘C. ⌘A selects all loaded text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !showHistory {
                empty("History hidden", symbol: "eye.slash")
            } else if service.history.isEmpty {
                empty(search.isEmpty ? "No transcripts yet" : "No matches", symbol: "text.alignleft")
            } else if historyTextView {
                SelectableHistory(transcripts: service.history, search: search)
                    .id(service.historyRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Text("Oldest to newest · New updates wait while text is selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if service.hasMoreHistory {
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
                                            Text(item.speakerLabel ?? item.speakerID ?? (item.mode == "dictation" ? "Dictation" : "Unknown speaker")).font(.caption.weight(.medium))

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
                                    if item.speakerID != nil && item.speakerID != "overlap" {
                                        Button("Name speaker") { selected = item; label = item.speakerLabel ?? "" }.font(.caption).buttonStyle(.link)
                                    }
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

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 18) {
                    GridRow { metric("Process CPU", String(format: "%.1f%%", service.resources.processCPUPercent)); metric("Memory", String(format: "%.0f MB", service.resources.residentMiB)) }
                    GridRow { metric("Memory footprint", String(format: "%.0f MB", service.resources.physicalFootprintMiB)); metric("Thermal state", service.resources.thermalState.capitalized) }
                    GridRow { metric("Queued audio", String(format: "%.1f s", service.queuedSeconds)); metric("Last inference", String(format: "%.2f s", service.lastInferenceSeconds)) }
                    GridRow { metric("Transcript lag", String(format: "%.2f s", service.lagSeconds)); metric("Dropped audio", String(format: "%.1f s", service.droppedSeconds)) }
                }
                Divider()
                Text("Capture events").font(.headline)
                ForEach(service.events) { event in
                    HStack(alignment: .top) {
                        Text(event.timestamp, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(event.detail).font(.callout)
                    }
                }
                if service.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tuning: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Mute built-in speakers during dictation", isOn: $service.muteSpeakersDuringDictation)
                        .toggleStyle(.switch)
                    Text("Restores the previous mute state when you release your shortcut. Other audio outputs are unchanged. Media keeps playing silently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Balanced") { service.tuning = .init() }
                    Button("Steadier speakers") { service.tuning = .steady }
                    Button("More detail") { service.tuning = .detailed }
                }.modifier(GlassButton())

                tuningSlider("Speaker confidence", value: $service.tuning.speakerConfidence, range: 0.45...0.9, step: 0.05,
                    valueText: String(format: "%.0f%%", service.tuning.speakerConfidence * 100),
                    detail: "Higher requires stronger evidence for a speaker label; more speech may remain unknown.")
                tuningSlider("Minimum speaker turn", value: $service.tuning.minimumSpeakerTurn, range: 0.2...2, step: 0.1,
                    valueText: String(format: "%.1f s", service.tuning.minimumSpeakerTurn),
                    detail: "Higher reduces speaker changes from brief hesitations. Short real replies may stay with the previous speaker.")
                tuningSlider("Pause between paragraphs", value: $service.tuning.paragraphPause, range: 0.3...2.5, step: 0.1,
                    valueText: String(format: "%.1f s", service.tuning.paragraphPause),
                    detail: "Longer pauses make fewer, longer rows. Nearby history rows from the same speaker are also grouped.")
                Toggle("Hide filler-only rows", isOn: $service.tuning.hideFillerRows).toggleStyle(.switch)

                Text("Hides rows containing only sounds such as um or uh. Original text is kept. Fillers inside sentences stay visible.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Speaker settings apply to new audio. Paragraph grouping and filler visibility also update saved history.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Try the same short scene twice. Change one setting, then compare words, speaker changes, and paragraph breaks separately.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text(valueText).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)

            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(service.modelState.capitalized).foregroundStyle(.secondary)
                    if service.cachedModelBytes > 0 {
                        Text("· \(ModelCache.formatted(service.cachedModelBytes)) cached").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(service.checkingModels ? "Checking…" : "Check updates") { service.checkModelUpdates() }
                        .disabled(service.checkingModels).modifier(GlassButton())

                }
                ForEach(service.modelUpdates) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            Link("Releases", destination: model.releasesURL)
                        }
                        Text(model.summary).font(.callout).foregroundStyle(.secondary)
                        if let checked = model.checkedAt { Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Updates are checked on demand. Downloaded models are kept until an update is explicitly installed.").font(.caption).foregroundStyle(.secondary)
                Link("FluidAudio releases", destination: URL(string: "https://github.com/FluidInference/FluidAudio/releases")!)
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
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit()) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}
