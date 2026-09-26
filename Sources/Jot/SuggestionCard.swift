import AppKit
import SwiftUI

@MainActor
final class SuggestionCard {
    /// One clickable choice, such as adding the latest meeting. Keys keep their meaning; this is mouse-only.
    struct Option {
        let title: String
        let action: @MainActor () -> Void
    }

    private var panel: NSPanel?
    private let model = CardModel()
    var isVisible: Bool { panel?.isVisible == true }

    func show(text: String, title: String = "Jot suggestion", sources: String = "", action: String = "Tab to insert",
              option: Option? = nil, loading: Bool = false, ready: Bool = false, at field: CGRect) {
        model.text = text; model.title = title; model.sources = sources; model.action = action
        model.option = option; model.loading = loading; model.ready = ready
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Clicks reach the card only while it has a choice; otherwise they pass through to the app underneath.
        panel.ignoresMouseEvents = option == nil
        place(at: field)
        panel.orderFrontRegardless()
    }
    func place(at field: CGRect) {
        guard let panel else { return }
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(field).area < b.frame.intersection(field).area
        } ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(420, bounds.width)
        let height = min(bounds.height, max(100, panel.contentView?.fittingSize.height ?? 130))
        var origin = CGPoint(x: field.minX, y: field.maxY + 8)
        if origin.y + height > bounds.maxY { origin.y = field.minY - height - 8 }
        origin.x = min(max(bounds.minX, origin.x), bounds.maxX - width)
        origin.y = min(max(bounds.minY, origin.y), bounds.maxY - height)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }
    func hide() { panel?.orderOut(nil) }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = CardHostingView(rootView: SuggestionCardView(model: model))
        return panel
    }
}

/// The borderless, nonactivating panel never becomes key, so a click here leaves Jot inactive and the target
/// field focused. Taking the first click makes the button work without an activating click first.
private final class CardHostingView: NSHostingView<SuggestionCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

@MainActor
private final class CardModel: ObservableObject {
    @Published var text = ""
    @Published var title = "Jot suggestion"
    @Published var sources = ""
    @Published var action = "Tab to insert"
    @Published var option: SuggestionCard.Option?
    @Published var loading = false
    @Published var ready = false
}

private struct SuggestionCardView: View {
    @ObservedObject var model: CardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "text.bubble").foregroundStyle(Color.accentColor) }
                Text(model.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(model.text).font(.body).fixedSize(horizontal: false, vertical: true)
            if !model.sources.isEmpty || model.option != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !model.sources.isEmpty {
                        Text(model.sources).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if let option = model.option {
                        Button(option.title) { option.action() }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            Text(model.ready ? "\(model.action) · Esc to dismiss" : "Esc to dismiss")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 388, alignment: .leading).padding(16)
        .modifier(CardMaterial())
        .accessibilityElement(children: .combine)
    }
}

private struct CardMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor.opacity(0.08)), in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.3)))
        }
    }
}
