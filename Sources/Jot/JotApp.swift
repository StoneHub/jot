import SwiftUI
import AppKit

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

struct JotBrand: View {
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

@MainActor
final class JotDelegate: NSObject, NSApplicationDelegate {
    let service = SpeechService()
    let updater = AppUpdater()
    weak var mainWindow: NSWindow?
    var openAction: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        redirectToInstalledCopy()
    }
    /// A Release build opened from anywhere but /Applications is a stale copy; hand off to the installed app instead of recording with old code.
    private func redirectToInstalledCopy() {
        #if !DEBUG
        let installed = AppUpdater.installPath
        guard Bundle.main.bundlePath != installed, FileManager.default.fileExists(atPath: installed) else { return }
        let alert = NSAlert()
        alert.messageText = "This is an old copy of Jot"
        alert.informativeText = "The installed Jot is in Applications. This copy will close and open that one."
        alert.addButton(withTitle: "Open Jot")
        alert.runModal()
        NSWorkspace.shared.open(URL(fileURLWithPath: installed))
        exit(0)
        #endif
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

struct WindowAttachment: NSViewRepresentable {
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
