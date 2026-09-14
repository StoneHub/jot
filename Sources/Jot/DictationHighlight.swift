import AppKit

/// A click-through outline over the field being dictated into, shown only while the shortcut is held.
/// The panel never activates, so the target keeps keyboard focus, and it follows the field if it moves.
@MainActor
final class DictationHighlight {
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastFrame = CGRect.zero

    func show(follow frame: @escaping () -> CGRect?) {
        guard let initial = frame() else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel, around: initial)
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                guard let current = frame() else { self.hide(); return }
                if current != self.lastFrame { self.place(panel, around: current) }
            }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    private func place(_ panel: NSPanel, around field: CGRect) {
        lastFrame = field
        panel.setFrame(field.insetBy(dx: -OutlineView.inset, dy: -OutlineView.inset), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = OutlineView()
        return panel
    }
}

/// Rounded accent-colored stroke that breathes so the eye finds it without it shouting.
private final class OutlineView: NSView {
    static let inset: CGFloat = 4
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2.5
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0; pulse.toValue = 0.35
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { layer?.borderColor = NSColor.controlAccentColor.cgColor }
}
