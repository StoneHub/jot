import SwiftUI
import AppKit

/// Liquid Glass on macOS 26, a material on earlier systems. `accent` washes the glass with the accent at a `JotTheme.Tint` strength.
struct GlassSurface: ViewModifier {
    @Environment(\.jotAccent) private var accentColor
    var accent: Double = 0
    var radius: CGFloat = JotTheme.Radius.surface
    func body(content: Content) -> some View {
        let tint = accent > 0 ? accentColor.opacity(accent) : .clear
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
struct GlassStage: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) { content }
        } else { content }
    }
}

struct JotBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.jotAccent) private var accent
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(colors: [accent.opacity(JotTheme.Tint.wash), .clear, .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [accent.opacity(0.05), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 500)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct NavigationSurface: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.modifier(GlassSurface(accent: JotTheme.Tint.selected, radius: JotTheme.Radius.panel))
        } else { content }
    }
}

/// A content card: padded, full width, on faintly tinted glass.
struct JotCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().padding(JotTheme.Padding.card).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface(accent: JotTheme.Tint.card, radius: JotTheme.Radius.card))
    }
}

/// The opaque rounded background behind a group of setting or list rows.
struct GroupSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: JotTheme.Radius.group))
    }
}

/// A recessed area inside a card, such as a preview result.
struct WellSurface: ViewModifier {
    var radius: CGFloat = JotTheme.Radius.panel
    func body(content: Content) -> some View {
        content.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: radius))
    }
}

/// Fills a shape behind the content with the accent at a `JotTheme.Tint` strength.
struct AccentFill<S: Shape>: ViewModifier {
    @Environment(\.jotAccent) private var accent
    var strength: Double
    var shape: S
    func body(content: Content) -> some View {
        content.background(accent.opacity(strength), in: shape)
    }
}

struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
struct PrimaryGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}
