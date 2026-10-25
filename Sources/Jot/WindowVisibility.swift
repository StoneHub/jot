import AppKit
import SwiftUI

/// Mounted SwiftUI content can outlive its window's visibility. Observe AppKit
/// once at the consumer boundary so hidden screens stop their periodic work.
struct WindowVisibility: NSViewRepresentable {
    var changed: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> WindowVisibilityView { WindowVisibilityView(changed: changed) }
    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.changed = changed
        view.updateVisibility()
    }
    static func dismantleNSView(_ view: WindowVisibilityView, coordinator: ()) { view.detach() }
}

final class WindowVisibilityView: NSView {
    var changed: @MainActor (Bool) -> Void
    private var visible: Bool?
    private var observers: [NSObjectProtocol] = []

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updateVisibility() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.detach() }
            })
        }
        Task { @MainActor [weak self] in self?.updateVisibility() }
    }

    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    func updateVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        publish(visible && !isHiddenOrHasHiddenAncestor)
    }

    private func publish(_ next: Bool) {
        guard visible != next else { return }
        visible = next
        let changed = changed
        // A representable may update during SwiftUI layout; publish afterward.
        DispatchQueue.main.async { changed(next) }
    }

    func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        publish(false)
    }
}
