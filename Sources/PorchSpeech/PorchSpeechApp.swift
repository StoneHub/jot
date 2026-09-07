import SwiftUI
import AppKit
import PorchCore

@main
struct PorchSpeechApp: App {
    @NSApplicationDelegateAdaptor(PorchDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Porch Speech", id: "status") {
            StatusView(service: delegate.service)
                .frame(minWidth: 660, minHeight: 600)
        }.defaultSize(width: 760, height: 720)
        MenuBarExtra {
            MenuControls(service: delegate.service)
        } label: {
            Image(systemName: delegate.service.mode.contains("ambient") || delegate.service.mode == "dictation" ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

@MainActor
final class PorchDelegate: NSObject, NSApplicationDelegate {
    let service = SpeechService()
    func applicationDidFinishLaunching(_ notification: Notification) { service.launch() }
    func applicationWillTerminate(_ notification: Notification) { service.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuControls: View {
    @ObservedObject var service: SpeechService
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Porch Speech · \(service.mode)")
        Text(String(format: "CPU %.1f%% · %.0f MB", service.resources.processCPUPercent, service.resources.residentMiB))
        Divider()
        Button("Open status") { openWindow(id: "status"); NSApp.activate(ignoringOtherApps: true) }
        Button("Start ambient listening") { Task { do { try await service.startAmbient() } catch { service.notice = error.localizedDescription } } }
            .disabled(service.modelState != "ready")
        Button("Pause microphone") { service.pause() }
        Button(service.fnEnabled ? "Disable Fn dictation" : "Enable Fn dictation") {
            if service.fnEnabled { service.disableFn() } else { Task { await service.enableFn() } }
        }
        Divider()
        Button("Quit Porch Speech") { NSApp.terminate(nil) }
    }
}

struct StatusView: View {
    @ObservedObject var service: SpeechService
    @State private var selected: Transcript?
    @State private var label = ""
    @State private var showRecent = true
    private let accent = Color(red: 0.34, green: 0.82, blue: 0.68)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PORCH SPEECH").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(accent)
                    Text("Your Mac, listening locally.").font(.system(size: 27, weight: .semibold))
                    Text("Fn dictation · Ambient transcripts · Four speaker slots").foregroundStyle(.secondary)
                }
                Spacer()
                Label(service.mode.capitalized, systemImage: service.mode.contains("ambient") ? "mic.fill" : "mic.slash")
                    .font(.callout.weight(.medium)).padding(10).background(accent.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 12) {
                Button(service.modelState == "ready" ? "Models ready" : "Prepare models") { service.prepare() }
                    .disabled(service.preparing || service.modelState == "ready")
                Button(service.fnEnabled ? "Disable Fn" : "Enable Fn") {
                    if service.fnEnabled { service.disableFn() } else { Task { await service.enableFn() } }
                }
                Button("Start ambient") { Task { do { try await service.startAmbient() } catch { service.notice = error.localizedDescription } } }
                    .disabled(service.modelState != "ready" || service.mode.contains("ambient"))
                Button("Pause mic") { service.pause() }.keyboardShortcut(".", modifiers: [.command])
            }.buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(service.modelState == "ready" ? accent : .orange).frame(width: 7, height: 7)
                    Text("Models: \(service.modelState)").font(.callout.weight(.medium))
                    Spacer()
                    Text("AUDIO STAYS IN MEMORY").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                }
                Text(service.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: min(1, Double(service.level) * 12)).tint(accent)
            }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 10) {
                metric("PROCESS CPU", String(format: "%.1f%%", service.resources.processCPUPercent), "100% = one core")
                metric("MEMORY", String(format: "%.0f MB", service.resources.residentMiB), "resident process memory")
                metric("QUEUE", String(format: "%.1f s", service.queuedSeconds), "audio awaiting inference")
                metric("THERMAL", service.resources.thermalState.capitalized, "system-wide state")
            }
            HStack {
                Text("Recent transcripts").font(.headline)
                Button(showRecent ? "Hide" : "Show") { showRecent.toggle() }.font(.caption)
                Spacer()
                Text(String(format: "Inference %.2fs · gaps %.1fs", service.lastInferenceSeconds, service.droppedSeconds)).font(.caption).foregroundStyle(.secondary)
            }
            if !showRecent {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(accent)
                    Text("History hidden").font(.headline)
                    Text("Saved transcripts remain available through search.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.recent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(accent)
                    Text("Ready when you are").font(.headline)
                    Text("Transcripts will appear here. Your agent can search them through the CLI or MCP.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(service.recent, id: \.id) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.speakerLabel ?? item.speakerID ?? (item.mode == "dictation" ? "Dictation" : "Unknown speaker"))
                                        .font(.caption.weight(.semibold)).foregroundStyle(accent)
                                    Text(item.startedAt.addingTimeInterval(item.startSeconds), style: .time).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if item.speakerID != nil && item.speakerID != "overlap" {
                                        Button("Name speaker") { selected = item; label = item.speakerLabel ?? "" }.font(.caption)
                                    }
                                }
                                Text(item.text).textSelection(.enabled).font(.callout)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            Text("Core ML requests CPU + Neural Engine. Actual accelerator placement is not measured here.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(28).background(Color(red: 0.055, green: 0.075, blue: 0.095)).preferredColorScheme(.dark)
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this session's speaker").font(.headline)
                Text("This label does not enroll a voice or carry identity into future sessions.").font(.callout).foregroundStyle(.secondary)
                TextField("Name", text: $label)
                HStack {
                    Button("Cancel") { selected = nil }
                    Spacer()
                    Button("Save label") {
                        guard let item = selected, let speaker = item.speakerID else { return }
                        Task {
                            let data = try! JSONSerialization.data(withJSONObject: ["method": "speakers.label", "params": ["sessionID": item.sessionID, "speakerID": speaker, "name": label]])
                            _ = await service.handle(data); selected = nil
                        }
                    }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 420)
        }
    }
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .medium, design: .rounded))
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
