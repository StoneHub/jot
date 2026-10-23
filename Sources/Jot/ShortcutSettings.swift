import AppKit
import SwiftUI
import JotCore

extension ShortcutModifiers {
    init(_ flags: CGEventFlags) {
        var value: Self = []
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        if flags.contains(.maskCommand) { value.insert(.command) }
        if flags.contains(.maskSecondaryFn) { value.insert(.fn) }
        self = value
    }
}

/// Which of Jot's shortcuts a button changes.
enum ShortcutPurpose {
    case dictation, suggestion, typoFix

    var title: String {
        switch self {
        case .dictation: return "Dictation shortcut"
        case .suggestion: return "Suggestion shortcut"
        case .typoFix: return "Fix typos shortcut"
        }
    }

    var explanation: String {
        switch self {
        case .dictation: return "Press a key with Control, Option, or Command. Hold to dictate; release to insert. Saved dictation is available from Review saved dictation."
        case .suggestion: return "Press a key with Control, Option, or Command. Request a draft using recent Jot context; Tab inserts without sending."
        case .typoFix: return "Press a key with Control, Option, or Command. Fixes typos in the selection, or the whole field when nothing is selected."
        }
    }
}

/// The shortcut button alone; the row that labels it lives with the other controls so it lines up with them.
struct ShortcutSettings: View {
    @ObservedObject var service: SpeechService
    var purpose = ShortcutPurpose.dictation
    @State private var showing = false
    var body: some View {
        Button(label) { showing = true }
            .font(.callout.monospaced()).accessibilityLabel("Change " + purpose.title.lowercased())
            .disabled(!service.canChangeShortcut)
            .popover(isPresented: $showing) {
                ShortcutEditor(service: service, purpose: purpose, dismiss: { showing = false })
            }
    }

    private var label: String {
        switch purpose {
        case .dictation: return service.shortcut.displayName
        case .suggestion: return service.suggestionShortcut?.displayName ?? "Choose shortcut…"
        case .typoFix: return service.typoFixShortcut.displayName
        }
    }
}

private struct ShortcutEditor: View {
    @ObservedObject var service: SpeechService
    let purpose: ShortcutPurpose
    let dismiss: () -> Void
    @State private var monitor: Any?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(purpose.title).font(.headline)
            Text(purpose.explanation)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Press shortcut…").font(.title3.monospaced())
                .frame(maxWidth: .infinity).padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: JotTheme.Radius.control))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Choose a shortcut you don’t use in other apps.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                switch purpose {
                case .dictation: Button("Use Fn / Globe") { save(.fn) }
                case .typoFix: Button("Use ⌃⌥Space") { save(TypoFixShortcutPreferences.standard) }
                case .suggestion: EmptyView()
                }
                Spacer()
                Button("Cancel", action: dismiss)
            }
        }
        .padding(18).frame(width: 320)
        .onAppear { begin() }
        .onDisappear { end() }
    }

    private func begin() {
        guard monitor == nil else { return }
        service.setShortcutRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { dismiss(); return }
                guard !event.isARepeat else { return }
                let flags = event.cgEvent.map { ShortcutModifiers($0.flags).subtracting(.fn) } ?? []
                let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "⌦",
                    123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
                    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
                    109: "F10", 103: "F11", 111: "F12"]
                let shortcut = DictationShortcut(keyCode: event.keyCode, modifiers: flags,
                    keyLabel: names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased())
                guard shortcut.isValid else { error = "Include Control, Option, or Command with a key."; return }
                save(shortcut)
            }
            return nil
        }
    }
    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        service.setShortcutRecording(false)
    }
    private func save(_ shortcut: DictationShortcut) {
        do {
            switch purpose {
            case .dictation: try service.setShortcut(shortcut)
            case .suggestion: try service.setSuggestionShortcut(shortcut)
            case .typoFix: try service.setTypoFixShortcut(shortcut)
            }
            end(); dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}
