import SwiftUI
#if DEBUG
import AppKit

struct TargetAnchor: Identifiable {
    let id = UUID()
    let target: FeedbackTarget
    let anchor: Anchor<CGRect>
    var viewports: [Anchor<CGRect>] = []
}
struct TargetPreference: PreferenceKey {
    static var defaultValue: [TargetAnchor] = []
    static func reduce(value: inout [TargetAnchor], nextValue: () -> [TargetAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

struct VisibleFeedbackTarget: Identifiable {
    let id: UUID
    let target: FeedbackTarget
    let sourceBounds: CGRect
    let visibleBounds: CGRect

    init?(id: UUID, target: FeedbackTarget, bounds: CGRect, viewports: [CGRect]) {
        let visible = viewports.reduce(bounds) { $0.intersection($1) }
        guard !visible.isNull, !visible.isInfinite, visible.width > 0, visible.height > 0 else { return nil }
        self.id = id
        self.target = target
        self.sourceBounds = bounds
        self.visibleBounds = visible
    }

    static func pick(at point: CGPoint, from targets: [Self]) -> Self? {
        targets.filter { $0.visibleBounds.contains(point) }
            .min { $0.sourceBounds.width * $0.sourceBounds.height < $1.sourceBounds.width * $1.sourceBounds.height }
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
                let resolved = targets.compactMap { target in
                    VisibleFeedbackTarget(id: target.id, target: target.target, bounds: geometry[target.anchor],
                                          viewports: target.viewports.map { geometry[$0] } + [CGRect(origin: .zero, size: geometry.size)])
                }
                let duplicates = Dictionary(grouping: resolved, by: { $0.target.id }).filter { $0.value.count > 1 }.count
                ZStack(alignment: .topTrailing) {
                    if session.picking {
                        // One hit surface prevents underlying app actions and resolves nested targets by area.
                        Color.black.opacity(0.08).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                if let hit = VisibleFeedbackTarget.pick(at: tap.location, from: resolved) {
                                    session.capture(hit.target, bounds: hit.sourceBounds, appearance: appearance == .dark ? "dark" : "light")
                                }
                            })
                        ForEach(resolved) { target in
                            let rect = target.visibleBounds
                            Rectangle().strokeBorder(.orange, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack(spacing: 8) {
                        if session.picking {
                            Text("Pick a highlighted view · \(resolved.count) visible targets")
                            Button("Cancel") { session.picking = false; session.showPanel() }
                                .keyboardShortcut(.cancelAction)
                        }
                        if session.picking && duplicates > 0 {
                            Text("\(duplicates) duplicate IDs").foregroundStyle(.red)
                                .help("Give repeated instances distinct, non-sensitive feedback IDs.")
                        }
                    }
                    .font(.caption).padding(session.picking ? 8 : 0)
                    .background {
                        if session.picking { RoundedRectangle(cornerRadius: 8).fill(.regularMaterial) }
                    }
                    .padding(session.picking ? 6 : 0)
                }
            }
        }
        .focusedSceneValue(\.devFeedbackSession, session)
        .onChange(of: screen) { _, value in session.updateScreen(value) }
    }
}
#endif

public extension View {
    /// Register a meaningful control or section. Use stable IDs and static labels, never user content.
    /// Repeated components should append a non-sensitive instance key. The source is this call site.
    #if DEBUG
    func feedbackTarget(_ id: String, label: String? = nil, file: String = #fileID, line: UInt = #line) -> some View {
        transformAnchorPreference(key: TargetPreference.self, value: .bounds) { targets, anchor in
            targets.append(TargetAnchor(target: FeedbackTarget(id: id, label: label ?? id, file: file, line: line), anchor: anchor))
        }
    }
    #else
    @inlinable
    func feedbackTarget(_ id: @autoclosure () -> String, label: @autoclosure () -> String? = nil,
                        file: String = #fileID, line: UInt = #line) -> Self { self }
    #endif

    /// Attach to each ScrollView or clipped container, outside its scrolling content.
    /// Both outlines and hit-testing respect all enclosing feedback viewports.
    #if DEBUG
    func feedbackViewport() -> some View {
        transformAnchorPreference(key: TargetPreference.self, value: .bounds) { targets, viewport in
            for index in targets.indices { targets[index].viewports.append(viewport) }
        }
    }
    #else
    @inlinable
    func feedbackViewport() -> Self { self }
    #endif

    /// Install once on each window's content, and separately on any sheet needing capture.
    /// Add FeedbackCommands to the scene to activate capture from its Developer menu.
    /// Idle views have no injected controls; Release builds return the original view.
    #if DEBUG
    @MainActor
    func feedbackOverlay(appID: String, screen: String) -> some View {
        modifier(FeedbackOverlay(appID: appID, screen: screen))
    }
    #else
    @MainActor @inlinable
    func feedbackOverlay(appID: @autoclosure () -> String, screen: @autoclosure () -> String) -> Self { self }
    #endif
}
