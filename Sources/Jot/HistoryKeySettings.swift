import AppKit
import JotCore
import SwiftUI

/// The history key, under Settings → Privacy. Showing it is for opening this Mac's history on another Mac; entering one
/// is for a history copied here that Jot could not unlock, so it is offered only while no history is open. The key is
/// read from the keychain when asked for, never kept in a view, and never written to the socket or a log.
struct HistoryKeySettings: View {
    @ObservedObject var service: SpeechService
    @State private var shownKey: String?
    @State private var copied = false
    @State private var enteredKey = ""
    @State private var notice: String?

    private var historyOpen: Bool { service.library.store != nil }

    var body: some View {
        SettingRow(title: "History key", info: "Saved history is encrypted. Its key stays in this Mac's login keychain, so a backup or a copy of Jot's folder is unreadable without it, and Jot and your agents never need it typed. To open this history on another Mac, show the key, keep it somewhere safe, and enter it there before the first launch with the copied folder.") {
            HStack(spacing: 8) {
                if shownKey != nil {
                    Button(copied ? "Copied" : "Copy key") { copy() }.modifier(GlassButton())
                    Button("Hide") { shownKey = nil; copied = false }.modifier(GlassButton())
                } else {
                    Button("Show key") { show() }.modifier(GlassButton()).disabled(!historyOpen)
                }
            }
        }
        if let shownKey {
            Text(shownKey).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .padding(.leading, JotTheme.Padding.row)
                .accessibilityLabel("History key")
        }
        if !historyOpen {
            RowDivider()
            SettingRow(title: "Enter a history key", info: "Jot could not open the saved history on this Mac. If it was copied from another Mac, enter that Mac's history key here, then quit and reopen Jot. The key replaces the one in this Mac's keychain.") {
                HStack(spacing: 8) {
                    TextField("64 hexadecimal digits", text: $enteredKey).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced)).frame(minWidth: 220)
                    Button("Use this key") { enter() }.modifier(GlassButton()).disabled(enteredKey.isEmpty)
                }
            }
        }
        if let notice {
            Text(notice).font(.caption).foregroundStyle(.secondary).padding(.leading, JotTheme.Padding.row)
        }
    }

    private func show() {
        do {
            guard let key = try StoreKeyStore.load() else { notice = "No history key is saved on this Mac yet."; return }
            shownKey = key.hex; copied = false; notice = nil
        } catch { notice = error.localizedDescription }
    }

    private func copy() {
        guard let shownKey else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(shownKey, forType: .string)
    }

    private func enter() {
        do {
            try StoreKeyStore.replace(with: try StoreKey(hex: enteredKey))
            enteredKey = ""
            notice = "Saved. Quit and reopen Jot to open the history with this key."
        } catch { notice = error.localizedDescription }
    }
}
