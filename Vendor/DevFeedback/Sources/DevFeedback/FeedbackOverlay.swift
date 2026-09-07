import SwiftUI
#if DEBUG
import AppKit

struct TargetAnchor: Identifiable {
    let id = UUID()
    let target: FeedbackTarget
    let anchor: Anchor<CGRect>
}
struct TargetPreference: PreferenceKey {
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
