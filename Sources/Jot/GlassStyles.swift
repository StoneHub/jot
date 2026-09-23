import SwiftUI
import AppKit

struct GlassSurface: ViewModifier {
    var tint: Color = .clear
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
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
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency {
                LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.10), .clear, .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.05), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 500)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct NavigationSurface: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.modifier(GlassSurface(tint: Color(nsColor: .controlAccentColor).opacity(0.14), radius: 14))
        } else { content }
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
