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
                print("PASS: real TranscriptView keeps download, permission and recovery guidance reachable across 720 pt, at 520 × 420, and on another page.")
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
