import SwiftUI
import AppKit
import JotCore

/// The Appearance setting: light, dark, or whatever the Mac uses. An unknown saved value, such as one typed into `jot settings`, reads as system.
enum JotAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// What NSApp takes; nil follows the Mac.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    init(saved: String) { self = Self(rawValue: saved) ?? .system }
}

/// The Accent setting: the Mac's accent color or one of a few system colors, which adapt to light and dark.
enum JotAccent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, orange, green
    var id: String { rawValue }
    var title: String { self == .system ? "Mac accent color" : rawValue.capitalized }
    var color: Color { Color(nsColor: nsColor) }
    /// For AppKit layers such as the field outline, which redraw from it rather than from the SwiftUI environment.
    var nsColor: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .green: .systemGreen
        }
    }
    init(saved: String) { self = Self(rawValue: saved) ?? .system }
    /// The saved choice, for code outside a SwiftUI view.
    static var current: JotAccent { JotAccent(saved: UserDefaults.standard.string(forKey: JotDefaultsKey.accentColor) ?? "") }
}

/// Keeps NSApp's appearance on the saved setting, so every window, the menu bar panel and the floating panels follow it,
/// including a change made with `jot settings`.
@MainActor
final class JotAppearanceFollower {
    private var observer: NSObjectProtocol?
    private var applied: JotAppearance?

    func start() {
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        let appearance = JotAppearance(saved: JotSettings.standard.text(JotDefaultsKey.appearance))
        guard appearance != applied else { return }
        applied = appearance
        NSApp.appearance = appearance.nsAppearance
    }
}
