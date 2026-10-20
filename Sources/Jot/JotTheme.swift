import SwiftUI
import AppKit

/// Jot's design tokens: the accent, corner radii, tint strengths, padding and display type its windows share.
/// Change a value here rather than at a call site, so one edit (or a theme) restyles every window.
enum JotTheme {
    /// The Mac's accent color. Views read the accent from `\.jotAccent`, which defaults to this, so a theme can replace it.
    static let systemAccent = Color(nsColor: .controlAccentColor)

    /// Corner radii, smallest first.
    enum Radius {
        static let badge: CGFloat = 5      // a small label such as Beta
        static let control: CGFloat = 8    // a field or key cap
        static let well: CGFloat = 10      // a result shown inside a card
        static let icon: CGFloat = 11      // a symbol tile in a card header
        static let group: CGFloat = 12     // a settings group, notice or list row
        static let panel: CGFloat = 14     // a selected sidebar row, the brand mark, a large well
        static let card: CGFloat = 16      // a content card
        static let surface: CGFloat = 22   // a window-level glass surface
    }

    /// How strongly a surface is washed with the accent, faintest first.
    enum Tint {
        static let card = 0.03
        static let panel = 0.04
        static let chip = 0.08
        static let wash = 0.10
        static let selected = 0.14
        static let stroke = 0.3
    }

    /// Insets for the containers that repeat across windows.
    enum Padding {
        static let row: CGFloat = 14
        static let card: CGFloat = 18
    }

    /// Display type. Body text keeps the system text styles (.headline, .callout, .caption).
    enum Display {
        static let pageTitle = Font.system(size: 26, weight: .bold, design: .rounded)
        static let brand = Font.system(size: 23, weight: .semibold, design: .rounded)
        static let stat = Font.system(size: 42, weight: .semibold, design: .rounded)
        static let identityIcon = Font.system(size: 34)
    }
}

private struct JotAccentKey: EnvironmentKey {
    static let defaultValue = JotTheme.systemAccent
}

extension EnvironmentValues {
    /// The color Jot tints with. Defaults to the Mac's accent color.
    var jotAccent: Color {
        get { self[JotAccentKey.self] }
        set { self[JotAccentKey.self] = newValue }
    }
}
