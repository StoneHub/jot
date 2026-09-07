import SwiftUI
#if DEBUG
import AppKit

private struct TargetAnchor: Identifiable {
    let id = UUID()
    let target: FeedbackTarget
    let anchor: Anchor<CGRect>
}
private struct TargetPreference: PreferenceKey {
    static var defaultValue: [TargetAnchor] = []
    static func reduce(value: inout [TargetAnchor], nextValue: () -> [TargetAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
private struct FeedbackOverlay: ViewModifier {
    @StateObject private var session: FeedbackSession
    private let screen: String
    @Environment(\.colorScheme) private var appearance

    init(appID: String, screen: String) {
        self.screen = screen
        _session = StateObject(wrappedValue: FeedbackSession(appID: appID, screen: screen))
    }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TargetPreference.self) { targets in
            GeometryReader { geometry in
                let resolved = targets.map { ($0, geometry[$0.anchor]) }
                let duplicates = Dictionary(grouping: targets, by: { $0.target.id }).filter { $0.value.count > 1 }.count
                ZStack(alignment: .topTrailing) {
                    if session.picking {
                        // One hit surface prevents underlying app actions and resolves nested targets by area.
                        Color.black.opacity(0.08).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                let hits = resolved.filter { $0.1.contains(tap.location) }
                                    .sorted { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
                                if let hit = hits.first {
                                    session.capture(hit.0.target, bounds: hit.1, appearance: appearance == .dark ? "dark" : "light")
                                }
                            })
                        ForEach(targets) { target in
                            let rect = geometry[target.anchor]
                            Rectangle().stroke(.orange, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack(spacing: 8) {
                        if session.picking {
                            Text("Pick a highlighted view · \(targets.count) targets")
                            Button("Cancel") { session.picking = false; session.showPanel() }
                                .keyboardShortcut(.cancelAction)
                        } else {
                            Button { session.showPanel() } label: {
                                Label("Feedback", systemImage: "bubble.left.and.text.bubble.right")
                            }.accessibilityIdentifier("dev-feedback.open")
                        }
                        if duplicates > 0 {
                            Text("\(duplicates) duplicate IDs").foregroundStyle(.red)
                                .help("Give repeated instances distinct, non-sensitive feedback IDs.")
                        }
                    }
                    .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(6)
                }
            }
        }
        .onChange(of: screen) { _, value in session.updateScreen(value) }
    }
}
#endif

public extension View {
    /// Register a meaningful control or section. Use stable IDs and static labels, never user content.
    /// Repeated components should append a non-sensitive instance key. The source is this call site.
    @ViewBuilder
    func feedbackTarget(_ id: String, label: String? = nil, file: String = #fileID, line: UInt = #line) -> some View {
        #if DEBUG
        anchorPreference(key: TargetPreference.self, value: .bounds) {
            [TargetAnchor(target: FeedbackTarget(id: id, label: label ?? id, file: file, line: line), anchor: $0)]
        }
        #else
        self
        #endif
    }

    /// Install once on each window's content, and separately on any sheet needing capture.
    /// DEBUG builds show a Feedback button; Release builds return the original view.
    @MainActor @ViewBuilder
    func feedbackOverlay(appID: String, screen: String) -> some View {
        #if DEBUG
        modifier(FeedbackOverlay(appID: appID, screen: screen))
        #else
        self
        #endif
    }
}
