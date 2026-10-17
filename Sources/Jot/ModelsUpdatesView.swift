import SwiftUI
import AppKit
import JotCore

/// Observed update wiring stays separate from the pure card used in owned window checks.
private struct AppUpdateRow: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var service: SpeechService
    var body: some View {
        AppUpdateCard(state: updater.state, isBusy: updater.isBusy,
                      check: updater.check, install: { updater.install(service: service) })
    }
}

struct AppUpdateCard: View {
    let state: AppUpdater.State
    let isBusy: Bool
    let check: () -> Void
    let install: () -> Void

    var body: some View {
        ModelsCardSurface {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { identity.fixedSize(); Spacer(minLength: 8); actions.fixedSize() }
                    VStack(alignment: .leading, spacing: 14) { identity; actions }
                }
                switch state {
                case .idle:
                    Text("Check for a new Jot release when you’re ready.").font(.callout).foregroundStyle(.secondary)
                case .checking:
                    Label("Checking GitHub releases…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                case .upToDate(let version):
                    Label("Jot \(version) is the latest release.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                case .available(let release):
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Version \(release.version.description) is available.").font(.callout.weight(.medium))
                        if !release.firstNoteLine.isEmpty {
                            Text(release.firstNoteLine).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .downloading(let fraction):
                    ProgressView(value: fraction) { Text("Downloading update…").font(.caption).foregroundStyle(.secondary) }
                case .finishing:
                    Text("Saving captured speech before relaunching…").font(.callout).foregroundStyle(.secondary)
                case .installing:
                    Text("Verifying and installing…").font(.callout).foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update-card")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 34))
                .foregroundStyle(.tint).frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Jot").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Version \(JotVersion.current) on this Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if case .available(let release) = state {
            HStack(spacing: 10) {
                Link("Release notes", destination: release.pageURL)
                Button("Update Jot", action: install).modifier(PrimaryGlassButton())
                    .accessibilityIdentifier("app-install-update")
                    .help("Downloads the release, saves captured speech, and relaunches Jot. Listening resumes automatically.")
            }
        } else {
            Button(state == .checking ? "Checking…" : "Check for updates", action: check)
                .disabled(isBusy).modifier(GlassButton())
                .accessibilityIdentifier("app-check-updates")
        }
    }
}

/// App releases and published model revisions are independent checks, initiated only by a button.
struct ModelsUpdatesView: View {
    @ObservedObject var service: SpeechService
    @ObservedObject var updater: AppUpdater

    var body: some View {
        GeometryReader { geometry in
            let count = min(3, max(1, Int((geometry.size.width + 16) / 286)))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppUpdateRow(updater: updater, service: service)
                    localModels
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count),
                              alignment: .leading, spacing: 16) {
                        ForEach(service.modelUpdates) { model in PublishedModelCard(model: model) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) { modelScope; Spacer(minLength: 8); fluidAudioLink.fixedSize() }
                        VStack(alignment: .leading, spacing: 10) { modelScope; fluidAudioLink }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
            }
        }
    }

    private var localModels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { modelIdentity.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 8); checkModels.fixedSize() }
            VStack(alignment: .leading, spacing: 12) { modelIdentity; checkModels }
        }
    }

    private var modelIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Label("Speech models", systemImage: "square.stack.3d.up").font(.headline)
                InfoButton(title: "Model updates", detail: "Checks published repository revisions only when you ask. Checking does not replace the local model cache.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { readiness; cacheSize }
                VStack(alignment: .leading, spacing: 6) { readiness; cacheSize }
            }
        }
    }

    private var readiness: some View {
        ModelsStatusBadge(title: readinessTitle, symbol: service.modelsLoaded ? "checkmark.circle" : "circle",
                          warning: service.modelState == .failed)
    }

    private var readinessTitle: String {
        switch service.modelState {
        case .ready: "Loaded and ready"
        case .preparing: "Loading models…"
        case .notLoaded: "Not loaded"
        case .unloaded: "Unloaded"
        case .unloading: "Unloading models…"
        case .failed: "Model loading failed"
        }
    }

    private var cacheSize: some View {
        Text(service.cachedModelBytes > 0 ? "\(ModelCache.formatted(service.cachedModelBytes)) in local cache" : "No cache recorded yet")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var checkModels: some View {
        Button(service.checkingModels ? "Checking…" : "Check model updates") { service.checkModelUpdates() }
            .disabled(service.checkingModels).modifier(GlassButton())
            .accessibilityIdentifier("model-check-updates")
    }

    private var modelScope: some View {
        Text("Published revisions describe the model repositories. The installed cache has no recorded revision; review releases before updating.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var fluidAudioLink: some View {
        Link("FluidAudio releases", destination: URL(string: "https://github.com/FluidInference/FluidAudio/releases")!)
            .font(.caption)
    }
}

private struct PublishedModelCard: View {
    let model: ModelUpdate
    private var name: String { model.name.components(separatedBy: " · ").first ?? model.name }
    private var role: String {
        if model.repository.contains("parakeet") { return "Speech to text" }
        if model.repository.contains("sortformer") { return "Speaker turns" }
        if model.repository.contains("silero") { return "Speech detection" }
        return "Speech model"
    }
    private var symbol: String {
        if model.repository.contains("parakeet") { return "waveform" }
        if model.repository.contains("sortformer") { return "person.2" }
        return "ear"
    }
    private var purpose: String {
        if model.repository.contains("parakeet") { return "Turns speech into words for dictation and listening." }
        if model.repository.contains("sortformer") { return "Separates who is speaking during a session." }
        if model.repository.contains("silero") { return "Detects when speech starts and stops." }
        return "Supports Jot’s local speech processing."
    }
    private var badge: String {
        if model.error != nil { return "Check failed" }
        if model.revision == nil { return "Not checked" }
        return model.changedSinceLastCheck ? "Changed since last check" : "Published revision"
    }

    var body: some View {
        ModelsCardSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.headline)
                        Text(role).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(purpose).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelsStatusBadge(title: badge, symbol: model.error != nil ? "exclamationmark.circle" : model.changedSinceLastCheck ? "arrow.triangle.2.circlepath" : "circle",
                                  warning: model.error != nil || model.changedSinceLastCheck)
                VStack(alignment: .leading, spacing: 7) {
                    metadata(model.error != nil ? "Last published revision" : "Revision", value: model.revision.map { String($0.prefix(8)) } ?? "—", monospaced: true)
                    if let published = model.publishedAt { metadata("Published", value: String(published.prefix(10))) }
                    if let checked = model.checkedAt {
                        metadata(model.error != nil ? "Last successful check" : "Checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("No successful check yet").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("View releases", destination: model.releasesURL).font(.callout)
                    .accessibilityLabel("View \(name) releases")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-card-\(model.repository)")
    }

    private func metadata(_ title: String, value: String, monospaced: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).foregroundStyle(.tertiary).fixedSize()
                Spacer(minLength: 4)
                Text(value).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.tertiary)
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
        }.font(monospaced ? .caption.monospaced() : .caption)
    }
}

private struct ModelsStatusBadge: View {
    let title: String
    let symbol: String
    var warning = false
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((warning ? Color.orange : Color.accentColor).opacity(0.08), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModelsCardSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.03), radius: 16))
    }
}
