import AppKit
import AVFoundation
import JotCore
import SwiftUI

/// Run the real TranscriptView in an owned window with a fresh CFFIXED_USER_HOME.
/// No service launch, socket, microphone, model download, permission request or installed app is involved.
@main
struct ServiceGuidanceChecks {
    final class ForbiddenMicrophone: MicrophoneSource {
        var running: Bool { false }
        var bufferedSampleCount: Int { 0 }
        func setInput(uid: String?) throws {}
        func setInputForNextStart(uid: String?) {}
        func shouldIgnoreConfigurationChange() -> Bool { false }
        func start() throws { fatalError("Window checks must never start capture") }
        func stop() {}
        func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
            ([], 0, .distantPast, 0)
        }
    }

    @MainActor static func main() {
        guard let isolatedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == URL(fileURLWithPath: isolatedHome).standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: JotPaths.directory.path),
              ModelCache.bytesOnDisk() == 0 else {
            fatalError("Use a fresh CFFIXED_USER_HOME; never run against the user's Jot data or models")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task {
            try? await Task.sleep(for: .seconds(45))
            fputs("FAIL: Window checks timed out\n", stderr)
            exit(2)
        }
        Task { @MainActor in
            do {
                try await run()
                print("PASS: requested synthetic window checks completed without capture or model work.")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    enum Failure: Error { case missing(String), outsideWindow(String), action(String), image }

    @MainActor static func run() async throws {
        let service = SpeechService(dependencies: .init(
            infer: { _, _, _ in fatalError("No inference in window checks") },
            deliver: { _, _ in fatalError("No dictation delivery in window checks") },
            now: Date.init,
            intelligenceAvailability: { .notEnabled },
            makeMicrophone: { ForbiddenMicrophone() },
            availableInputs: { [] }, defaultInputUID: { nil },
            prepareModels: { _ in fatalError("No model download in window checks") },
            microphoneAuthorization: { .denied },
            requestMicrophoneAccess: { fatalError("No permission request in window checks") }))
        service.micPermission = .authorized
        service.accessibilityGranted = true
        if ProcessInfo.processInfo.environment["JOT_MODELS_WINDOW_CHECKS"] == "1" {
            try await checkModels(service)
            return
        }
        if ProcessInfo.processInfo.environment["JOT_ACTIVITY_WINDOW_CHECKS"] == "1" {
            try await checkActivity(service)
            return
        }
        let delegate = JotDelegate() // Not the NSApp delegate: applicationDidFinishLaunching is never called.
        let root = TranscriptView(service: service, library: service.library, setup: SetupFlow(), delegate: delegate)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Jot synthetic window checks"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        await settle(window)

        // Actual Resume, with an empty model cache, must reveal the download question in rail mode.
        window.setContentSize(NSSize(width: 719, height: 760))
        await settle(window)
        try snapshot(host, name: "719-before-resume")
        try press("service-pause-resume", in: host)
        await settle(window)
        precondition(service.downloadPrompt != nil, "Resume did not request the first model download")
        try snapshot(host, name: "719-first-resume")
        try require("confirm-model-download", in: host, window: window, visible: true)
        try pressLabel("Not now", in: host)
        await settle(window)
        precondition(service.downloadPrompt == nil, "Not now did not dismiss the question")
        precondition(find("confirm-model-download", in: host) == nil, "Dismissed download question is still shown")

        // Recovery and permissions coexist; every state must survive both sides of the rail boundary.
        service.micPermission = .denied
        service.accessibilityGranted = false
        service.recoveryNotice = "Some dictated speech could not be inserted. Review saved dictation to copy the saved text."
        for width in [920.0, 720.0, 719.0, 520.0] {
            window.setContentSize(NSSize(width: width, height: 760))
            await settle(window)
            for id in ["fix-permissions", "review-saved-dictation", "dictation-recovery-notice"] {
                try require(id, in: host, window: window, visible: true)
            }
            try snapshot(host, name: "\(Int(width))-recovery-permissions")
        }

        // The smallest supported window bounds combined guidance and keeps navigation available.
        service.downloadPrompt = ModelCache.expectedBytes
        service.recoveryNotice = Array(repeating: "Some dictated speech could not be inserted. Review saved dictation to copy the saved text.", count: 4).joined(separator: " ")
        window.setContentSize(NSSize(width: 520, height: 420))
        await settle(window)
        for id in ["confirm-model-download", "fix-permissions", "review-saved-dictation", "dictation-recovery-notice"] {
            try require(id, in: host, window: window, visible: false)
        }
        try require("service-pause-resume", in: host, window: window, visible: true)
        try snapshot(host, name: "520x420-combined-guidance")
        try pressLabel("Dictations", in: host)
        await settle(window)
        try require("confirm-model-download", in: host, window: window, visible: false)
        try require("fix-permissions", in: host, window: window, visible: false)
        try snapshot(host, name: "520x420-dictations")

        // Scroll every action into the actual viewport; do not press permission/download actions.
        for id in ["confirm-model-download", "fix-permissions", "review-saved-dictation"] {
            try await reveal(id, in: host, window: window)
            try snapshot(host, name: "520x420-scrolled-\(id)")
        }

        for width in [720.0, 719.0, 920.0, 520.0, 720.0, 719.0] {
            window.setContentSize(NSSize(width: width, height: 760))
            await settle(window)
            for id in ["confirm-model-download", "fix-permissions", "review-saved-dictation", "dictation-recovery-notice"] {
                try require(id, in: host, window: window, visible: false)
            }
            for id in ["confirm-model-download", "fix-permissions", "review-saved-dictation"] {
                try await reveal(id, in: host, window: window)
            }
        }

        service.downloadPrompt = nil
        service.recoveryNotice = ""
        service.micPermission = .authorized
        service.accessibilityGranted = true
        window.setContentSize(NSSize(width: 520, height: 420))
        await settle(window)
        for id in ["confirm-model-download", "fix-permissions", "dictation-recovery-notice"] {
            precondition(find(id, in: host) == nil, "Resolved guidance remained: \(id)")
        }
        try snapshot(host, name: "520x420-resolved")
        precondition(!service.capture.running && !service.modelsLoaded, "Window checks changed capture or model state")
        window.orderOut(nil)
        try await checkActivity(service)
    }

    /// Model metadata and update states are invented; no release checks or downloads run.
    @MainActor static func checkModels(_ service: SpeechService) async throws {
        let baseline = ProcessInfo.processInfo.environment["JOT_MODELS_BASELINE"] == "1"
        let delegate = JotDelegate()
        var models = ModelUpdate.defaults
        for index in models.indices {
            models[index].revision = String(repeating: String(index + 1), count: 40)
            models[index].publishedAt = "2026-10-01T12:00:00Z"
            models[index].checkedAt = Date(timeIntervalSince1970: 1_791_072_000)
        }
        models[1].changedSinceLastCheck = true
        service.modelUpdates = models
        let releaseJSON = #"{"tag_name":"v9.9.9","html_url":"https://example.com/release","body":"Synthetic release notes.","assets":[{"name":"Jot-9.9.9.zip","browser_download_url":"https://example.com/Jot-9.9.9.zip","size":12345}],"draft":false}"#
        let release = try ReleaseInfo.latest(from: Data(releaseJSON.utf8)) { "Jot-\($0).zip" }
        for width in [1440.0, 1040.0, 720.0, 520.0] {
            let host = NSHostingView(rootView: TranscriptView(service: service, library: service.library, setup: SetupFlow(), delegate: delegate))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Jot synthetic Models checks"
            window.contentView = host
            window.center(); window.makeKeyAndOrderFront(nil)
            await settle(window)
            try pressLabel("Models & updates", in: host)
            await settle(window)
            try snapshot(host, name: "models-\(Int(width))-top")
            if !baseline {
                try await reveal("app-check-updates", in: host, window: window)
                try await reveal("model-check-updates", in: host, window: window)
                for model in models {
                    try await reveal("model-card-\(model.repository)", in: host, window: window)
                }
                try snapshot(host, name: "models-\(Int(width))-cards")
                if width == 520 {
                    service.checkingModels = true
                    await settle(window)
                    precondition(find("model-check-updates", in: host)?.isAccessibilityEnabled() == false,
                                 "Model check stays disabled during an in-flight check")
                    try snapshot(host, name: "models-520-checking")
                    service.checkingModels = false
                    service.modelUpdates = ModelUpdate.defaults
                    service.modelUpdates[0].error = "The server could not be reached. Check your connection and try again."
                    await settle(window)
                    try await reveal("model-card-\(models[0].repository)", in: host, window: window)
                    try snapshot(host, name: "models-520-error-notchecked")
                }
            }
            window.orderOut(nil)
        }
        precondition(!service.capture.running && !service.modelsLoaded && service.library.store == nil,
                     "Models window fixtures must not touch capture, models or history")
        if !baseline { try await checkAppUpdateStates(release) }
        print("PASS: Models layouts and on-demand update states remain reachable without network or capture work.")
    }

    @MainActor static func checkAppUpdateStates(_ release: ReleaseInfo) async throws {
        let states: [(String, AppUpdater.State, Bool)] = [
            ("available", .available(release), false), ("checking", .checking, true),
            ("downloading", .downloading(0.42), true), ("finishing", .finishing, true),
            ("installing", .installing, true), ("current", .upToDate("0.3.2"), false),
            ("error", .failed("The connection is unavailable. Check your connection and try again."), false)
        ]
        for (name, state, busy) in states {
            var checks = 0, installs = 0
            let host = NSHostingView(rootView: ScrollView {
                AppUpdateCard(state: state, isBusy: busy, check: { checks += 1 }, install: { installs += 1 })
                    .padding(16)
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jot synthetic app update"
            window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
            await settle(window)
            let action = name == "available" ? "app-install-update" : "app-check-updates"
            try require(action, in: host, window: window, visible: true)
            if busy {
                precondition(find(action, in: host)?.isAccessibilityEnabled() == false,
                             "Busy updater must not start another check")
            } else {
                try press(action, in: host)
                precondition(name == "available" ? installs == 1 && checks == 0 : checks == 1 && installs == 0,
                             "Update card invoked the wrong action")
            }
            try snapshot(host, name: "app-update-380-\(name)")
            window.orderOut(nil)
        }
    }

    /// Render only invented aggregates. No store is opened and no transcript text is needed.
    @MainActor static func checkActivity(_ service: SpeechService) async throws {
        service.resourceReadout.snapshot = ResourceSnapshot(valid: true, processCPUPercent: 7.5,
            residentMiB: 624, physicalFootprintMiB: 590, thermalState: "nominal")
        service.diagnostics = PerformanceDiagnostics(build: .debug)
        precondition(ActivityTrendSnapshot(report: service.diagnostics.report).points.isEmpty,
                     "An empty diagnostic buffer must not invent a trend")
        for index in 0...15 where !(5...7).contains(index) {
            service.diagnostics.observe(PerformanceSample(elapsedSeconds: Double(index * 60),
                footprintMiB: 110 + Double(index % 8) * 3,
                residentMiB: 235 + Double(index % 6) * 4,
                cpuPercent: 4 + Double(index % 5) * 7))
        }
        let trend = ActivityTrendSnapshot(report: service.diagnostics.report)
        precondition(trend.points.count == 13 && Set(trend.points.map(\.segment)).count == 2,
                     "Trend lines must preserve every retained sample and break across the measurement gap")
        precondition(trend.points.first?.minutesBeforeLatest == -15 && trend.points.last?.minutesBeforeLatest == 0,
                     "Trend scope must be relative to the latest reading")
        var single = PerformanceDiagnostics(build: .debug)
        single.observe(PerformanceSample(elapsedSeconds: 0, footprintMiB: 10, residentMiB: 20, cpuPercent: 3))
        let singleTrend = ActivityTrendSnapshot(report: single.report)
        precondition(singleTrend.points.count == 1 && singleTrend.points[0].isolated,
                     "A single sample must remain visible as a point")
        let report = activityFixture(days: 7)
        for width in [1440.0, 920.0, 520.0] {
            let host = NSHostingView(rootView: ActivityFixturePage(service: service, report: report, error: nil, width: width))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Jot synthetic Activity checks"
            window.contentView = host
            window.center(); window.makeKeyAndOrderFront(nil)
            await settle(window)
            // Trend state arrives in a task after the first layout; wait for the actual view,
            // rather than racing its second accessibility-tree publication.
            for _ in 0..<10 {
                if find("activity-live-stats", in: host) != nil { break }
                await settle(window)
            }
            try snapshot(host, name: "activity-\(Int(width))-ready")
            try require("activity-live-stats", in: host, window: window, visible: true)
            precondition(find("activity-advanced", in: host) == nil, "Activity has no hidden diagnostics section")
            precondition(!elements(host).contains(where: { $0.accessibilityLabel() == "Recent capture events" }),
                         "Activity must not display capture events")
            try snapshot(host, name: "activity-\(Int(width))-top")
            for id in ["activity-cpu-trend", "activity-memory-trend"] {
                try await reveal(id, in: host, window: window)
            }
            precondition(!elements(host).contains(where: { $0.accessibilityLabel() == "Collecting measurements…" }),
                         "Seeded diagnostic samples must render real trend charts")
            try snapshot(host, name: "activity-\(Int(width))-trends")
            try await reveal("activity-period", in: host, window: window)
            try await reveal("activity-dictation-words", in: host, window: window)
            try snapshot(host, name: "activity-\(Int(width))-summary")
            try await reveal("activity-daily-chart", in: host, window: window)
            try snapshot(host, name: "activity-\(Int(width))-chart")
            guard elements(host).contains(where: { ($0.accessibilityLabel() ?? "").contains("Daily saved dictation words") }) else {
                throw Failure.missing("Daily saved dictation words accessibility label")
            }
            window.orderOut(nil)
        }
        for state in ["empty", "error", "30-days"] {
            let fixture = state == "error" ? nil : activityFixture(days: state == "30-days" ? 30 : 7, empty: state == "empty")
            let error = state == "error" ? "Saved history is unavailable. Jot will try again while this page is open." : nil
            let host = NSHostingView(rootView: ActivityFixturePage(service: service, report: fixture, error: error, width: 520))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Jot synthetic Activity checks"
            window.contentView = host
            window.center(); window.makeKeyAndOrderFront(nil)
            await settle(window)
            try require(state == "error" ? "activity-error" : state == "empty" ? "activity-empty" : "activity-daily-chart",
                        in: host, window: window, visible: false)
            try snapshot(host, name: "activity-520-\(state)")
            window.orderOut(nil)
        }
        precondition(!service.capture.running && !service.modelsLoaded && service.library.store == nil,
                     "Activity fixtures must not change capture, models or open history")
    }

    @MainActor struct ActivityFixturePage: View {
        let service: SpeechService
        let report: ActivityReport?
        let error: String?
        let width: Double
        var body: some View {
            HStack(spacing: 14) {
                Color.clear.frame(width: width >= 720 ? 282 : 48)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Activity").font(.system(size: 26, weight: .bold, design: .rounded))
                    ActivityView(service: service, library: service.library, fixture: report, fixtureError: error)
                        .environment(\.scenePhase, .active)
                }.padding(width >= 720 ? 24 : 16).modifier(GlassSurface())
            }.padding(16).background(JotBackdrop()).tint(Color(nsColor: .controlAccentColor))
        }
    }

    static func activityFixture(days: Int, empty: Bool = false) -> ActivityReport {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        let counts = [84, 0, 236, 154, 450, 98, 196]
        let daily = (0..<days).map { index in
            let words = empty ? 0 : counts[index % counts.count]
            return ActivityDay(date: calendar.date(byAdding: .day, value: index, to: start)!,
                dictation: .init(wordCount: words, segmentCount: words > 0 ? 4 : 0, sessionCount: words > 0 ? 1 : 0,
                                speechWindowSeconds: Double(words) / 2.2, activeDays: words > 0 ? 1 : 0),
                ambient: .init(wordCount: empty ? 0 : 1350, segmentCount: empty ? 0 : 20, sessionCount: empty ? 0 : 1,
                               speechWindowSeconds: empty ? 0 : 780, activeDays: empty ? 0 : 1),
                verifiedDictationDeliveries: empty ? 0 : 4)
        }
        return ActivityReport(generatedAt: now, windowStart: start, windowEnd: now, days: days,
            timeZoneIdentifier: calendar.timeZone.identifier,
            dictation: .init(wordCount: daily.reduce(0) { $0 + $1.dictation.wordCount },
                            segmentCount: empty ? 0 : days * 4, sessionCount: empty ? 0 : days,
                            speechWindowSeconds: daily.reduce(0) { $0 + $1.dictation.speechWindowSeconds },
                            activeDays: daily.filter { $0.dictation.wordCount > 0 }.count),
            ambient: .init(wordCount: empty ? 0 : days * 1350, segmentCount: empty ? 0 : days * 20,
                           sessionCount: empty ? 0 : days, speechWindowSeconds: empty ? 0 : Double(days * 780),
                           activeDays: empty ? 0 : days), verifiedDictationDeliveries: empty ? 0 : days * 4, daily: daily)
    }

    @MainActor static func settle(_ window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// SwiftUI's accessibility nodes implement the AppKit selectors without declaring NSAccessibilityProtocol.
    @MainActor struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            let selector = NSSelectorFromString(key)
            let booleanSelector = NSSelectorFromString("is" + key.prefix(1).uppercased() + key.dropFirst())
            guard object.responds(to: selector) || object.responds(to: booleanSelector) else { return nil }
            return object.value(forKey: key)
        }
        func accessibilityIdentifier() -> String? { value("accessibilityIdentifier") as? String }
        func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
        func accessibilityTitle() -> String? { value("accessibilityTitle") as? String }
        func accessibilityRole() -> NSAccessibility.Role? {
            (value("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
        }
        func accessibilityChildren() -> [Any]? { value("accessibilityChildren") as? [Any] }
        func accessibilityFrame() -> NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        func isAccessibilityEnabled() -> Bool { value("accessibilityEnabled") as? Bool ?? false }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
            let press = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return press(object, selector)
        }
    }

    @MainActor static func elements(_ root: NSObject) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [Element] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let element = Element(object: node)
            return [element] + (element.accessibilityChildren() ?? []).flatMap { child in
                (child as? NSObject).map(walk) ?? []
            }
        }
        return walk(root)
    }

    @MainActor static func find(_ id: String, in host: NSView) -> Element? {
        elements(host).first { $0.accessibilityIdentifier() == id }
    }

    @MainActor static func require(_ id: String, in host: NSView, window: NSWindow, visible: Bool) throws {
        guard let element = find(id, in: host) else { throw Failure.missing(id) }
        if visible {
            let frame = element.accessibilityFrame()
            let content = window.convertToScreen(window.contentView!.bounds)
            let viewports = owningScrolls(id, in: host).map { scroll in
                window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            }
            if id != "service-pause-resume" && viewports.isEmpty { throw Failure.missing("scroll viewport for \(id)") }
            guard frame.width > 0 && frame.height > 0 && content.insetBy(dx: -1, dy: -1).contains(frame),
                  viewports.allSatisfy({ $0.insetBy(dx: -1, dy: -1).contains(frame) }) else {
                print("Outside viewport: \(id); AX frame=\(frame); window=\(content); scroll viewports=\(viewports)")
                throw Failure.outsideWindow(id)
            }
        }
        print("PASS: \(Int(host.bounds.width)) × \(Int(host.bounds.height)): \(id)\(visible ? " visible within viewport" : " present")")
    }

    @MainActor static func owningScrolls(_ id: String, in host: NSView) -> [NSScrollView] {
        descendants(host).compactMap { $0 as? NSScrollView }.filter { scroll in
            elements(scroll).contains { $0.accessibilityIdentifier() == id }
        }
    }

    @MainActor static func reveal(_ id: String, in host: NSView, window: NSWindow) async throws {
        guard let element = find(id, in: host), element.isAccessibilityEnabled() else { throw Failure.missing(id) }
        let scrolls = owningScrolls(id, in: host)
        guard !scrolls.isEmpty else { throw Failure.missing("scroll viewport for \(id)") }
        for scroll in scrolls {
            guard let document = scroll.documentView else { throw Failure.missing("scroll document for \(id)") }
            document.scrollToVisible(document.convert(window.convertFromScreen(element.accessibilityFrame()), from: nil))
        }
        await settle(window)
        try require(id, in: host, window: window, visible: true)
    }

    @MainActor static func press(_ id: String, in host: NSView) throws {
        guard let button = find(id, in: host), button.isAccessibilityEnabled(), button.accessibilityPerformPress() else {
            for node in elements(host) {
                print("AX: \(type(of: node)) \(node.accessibilityRole()?.rawValue ?? "") id=\(node.accessibilityIdentifier() ?? "") label=\(node.accessibilityLabel() ?? "") title=\(node.accessibilityTitle() ?? "") enabled=\(node.isAccessibilityEnabled()) children=\(node.accessibilityChildren()?.count ?? 0)")
            }
            throw Failure.action(id)
        }
    }

    @MainActor static func pressLabel(_ label: String, in host: NSView) throws {
        guard let button = elements(host).first(where: {
            $0.accessibilityRole() == .button && ($0.accessibilityLabel() == label || $0.accessibilityTitle() == label)
        }), button.accessibilityPerformPress() else { throw Failure.action(label) }
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor static func snapshot(_ host: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["JOT_WINDOW_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let window = host.window else { throw Failure.image }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw Failure.image }
    }
}
