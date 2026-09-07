import SwiftUI
import AppKit
import JotCore
#if DEBUG
import DevFeedback
#else
private extension View {
    func feedbackTarget(_ id: String, label: String? = nil, file: String = #fileID, line: UInt = #line) -> some View { self }
    func feedbackOverlay(appID: String, screen: String) -> some View { self }
    func feedbackViewport() -> some View { self }
}
#endif

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
            #if DEBUG
            FeedbackCommands()
            #endif
        }
        MenuBarExtra {
            MenuControls(service: delegate.service, delegate: delegate)
        } label: {
            Image(nsImage: JotMenuIcon.image)
                .accessibilityLabel("Jot controls")
                .help("Jot — open speech controls")
        }.menuBarExtraStyle(.window)
    }
}

/// The same five rounded waveform bars as the app icon, drawn as a native
/// template so macOS supplies contrast against light and dark menu bars.
private enum JotMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (index, height) in [5.0, 10, 16, 10, 5].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 1 + Double(index) * 3.4,
                    y: (18 - height) / 2, width: 2.5, height: height),
                    xRadius: 1.25, yRadius: 1.25).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Jot"
        return image
    }()
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
            Image(nsImage: JotMenuIcon.image)
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

private struct GlassButton: ViewModifier {
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

private struct ServiceControls: View {
    @ObservedObject var service: SpeechService
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle().fill(service.isPaused ? Color.secondary : .green).frame(width: 7, height: 7)
                        Text(service.isPaused ? "Paused" : (service.isTransitioning ? "Starting" : "Ready"))
                    }.font(.headline)
                    Text(service.isPaused ? (service.lifecycle.phase == .pausing ? "Releasing models…" : "Models unloaded") : (service.ambientEnabled ? "Ambient transcription on" : "Ambient transcription off"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if service.isPaused { service.prepare() } else { service.pause() }
                } label: {
                    Label(service.isPaused ? "Resume" : "Pause", systemImage: service.isPaused ? "play.fill" : "pause.fill")
                }
                .modifier(PrimaryGlassButton())
                .disabled(service.lifecycle.phase == .pausing)
                .help("Pause stops all speech work and unloads models.")
                .accessibilityIdentifier("service-pause-resume")
                .feedbackTarget("service.pause-resume", label: "Pause or resume service")
            }
            Divider()
            Toggle(isOn: Binding(get: { service.fnRequested }, set: { enabled in
                if enabled { Task { await service.enableFn() } } else { service.disableFn() }
            })) {
                Label("Fn dictation", systemImage: "fn")
            }.toggleStyle(.switch).help("Hold Fn to dictate into the focused text field.")
                .feedbackTarget("service.fn", label: "Fn dictation")
            Toggle(isOn: Binding(get: { service.ambientRequested }, set: { enabled in
                Task { await service.setAmbient(enabled) }
            })) {
                Label("Ambient transcription", systemImage: "mic")
            }.toggleStyle(.switch).help("Continuously transcribe the microphone while the service is running.")
                .feedbackTarget("service.ambient", label: "Ambient transcription")
            if service.isPaused && (service.fnRequested || service.ambientRequested) {
                Text("Selected features start when you resume.").font(.caption).foregroundStyle(.secondary)
            }
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

/// Opaque UI-instance keys let the picker distinguish rows without exporting
/// transcript IDs, speaker names, timestamps, or text as target metadata.
#if DEBUG
private final class HistoryFeedbackKeys: ObservableObject {
    private var keys: [String: String] = [:]
    func key(for transcriptID: String) -> String {
        if let key = keys[transcriptID] { return key }
        let key = UUID().uuidString
        keys[transcriptID] = key
        return key
    }
}

#endif

struct TranscriptView: View {
    @ObservedObject var service: SpeechService
    let delegate: JotDelegate
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @StateObject private var feedbackKeys = HistoryFeedbackKeys()
    #endif
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
                    ForEach(["History", "Activity", "Tuning", "Models"], id: \.self) { item in
                        Button { section = item } label: {
                            Label(item, systemImage: item == "History" ? "text.alignleft" : (item == "Activity" ? "chart.xyaxis.line" : (item == "Tuning" ? "slider.horizontal.3" : "square.stack.3d.up")))
                                .font(.body.weight(section == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                                .modifier(NavigationSurface(selected: section == item))
                        }.buttonStyle(.plain)
                            .feedbackTarget("navigation.\(item.lowercased())", label: "Open \(item)")
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
                        .feedbackTarget("history.finder", label: "Open History in Finder")
                        Button(showHistory ? "Hide" : "Show", systemImage: showHistory ? "eye.slash" : "eye") { showHistory.toggle() }
                            .modifier(GlassButton())
                            .feedbackTarget("history.visibility", label: "Show or hide history")
                    }
                }
                if !service.notice.isEmpty {
                    Text(service.notice).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if section == "History" { history }
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
        .feedbackOverlay(appID: "jot", screen: section.lowercased())
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
                .feedbackTarget("history.search", label: "Search transcripts")
            if showHistory {
                HStack {
                    Picker("History view", selection: $historyTextView) {
                        Text("Text").tag(true)
                        Text("Cards").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        .accessibilityLabel("History view")
                        .feedbackTarget("history.view", label: "Text or cards history")
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .feedbackTarget("history.text-document", label: "Selectable transcript document")
                HStack {
                    Text("Oldest to newest · New updates wait while text is selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if service.hasMoreHistory {
                        Button("Load more") { service.loadMoreHistory() }
                            .feedbackTarget("history.load-more", label: "Load more history")
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(service.history) { item in
                            #if DEBUG
                            let key = "history.row." + feedbackKeys.key(for: item.id)
                            #else
                            let key = ""
                            #endif
                            VStack(alignment: .leading, spacing: 8) {
                                Button { copy(item) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(item.speakerLabel ?? item.speakerID ?? (item.mode == "dictation" ? "Dictation" : "Unknown speaker")).font(.caption.weight(.medium))
                                                .feedbackTarget(key + ".speaker", label: "Mode or speaker label")
                                            Spacer()
                                            Text(item.startedAt.addingTimeInterval(item.startSeconds), format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                                .feedbackTarget(key + ".timestamp", label: "Transcript timestamp")
                                            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc").foregroundStyle(copiedID == item.id ? .green : .secondary)
                                                .feedbackTarget(key + ".copy-icon", label: "Copy indicator")
                                        }
                                        Text(item.text).font(.body).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                            .feedbackTarget(key + ".text", label: "Transcript text")
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(copiedID == item.id ? "Copied" : "Copy transcript")
                                    .feedbackTarget(key + ".copy", label: "Copy transcript")
                                    .accessibilityLabel("Copy \(item.mode) transcript")
                                    .accessibilityValue(copiedID == item.id ? "Copied" : item.text)
                                if item.speakerID != nil && item.speakerID != "overlap" {
                                    Button("Name speaker") { selected = item; label = item.speakerLabel ?? "" }.font(.caption).buttonStyle(.link)
                                        .feedbackTarget(key + ".name-speaker", label: "Name speaker")
                                }
                            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                                .feedbackTarget(key + ".card", label: "Transcript card")
                        }
                        if service.hasMoreHistory {
                            Button("Load more") { service.loadMoreHistory() }.frame(maxWidth: .infinity)
                                .feedbackTarget("history.load-more", label: "Load more history")
                        }
                    }
                }.feedbackViewport()
            }
        }.feedbackTarget("history.content", label: "Transcript history")
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
        }.feedbackViewport().feedbackTarget("activity.metrics", label: "Resource metrics and capture events")
    }

    private var tuning: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Button("Balanced") { service.tuning = .init() }
                    Button("Steadier speakers") { service.tuning = .steady }
                    Button("More detail") { service.tuning = .detailed }
                }.modifier(GlassButton())
                    .feedbackTarget("tuning.presets", label: "Tuning presets")
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
                    .feedbackTarget("tuning.fillers", label: "Hide filler-only rows")
                Text("Hides rows containing only sounds such as um or uh. Original text is kept. Fillers inside sentences stay visible.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Speaker settings apply to new audio. Paragraph grouping and filler visibility also update saved history.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Try the same short scene twice. Change one setting, then compare words, speaker changes, and paragraph breaks separately.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.feedbackViewport()
    }

    private func tuningSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text(valueText).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
                .feedbackTarget("tuning.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))", label: title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(service.modelState.capitalized).foregroundStyle(.secondary)
                    Spacer()
                    Button(service.checkingModels ? "Checking…" : "Check updates") { service.checkModelUpdates() }
                        .disabled(service.checkingModels).modifier(GlassButton())
                        .feedbackTarget("models.check", label: "Check model updates")
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
        }.feedbackViewport()
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
