import AppKit

/// A click-through outline over the field being dictated into, shown from the shortcut press until the text is inserted.
/// The panel never activates, so the target keeps keyboard focus, and it follows the field if it moves.
@MainActor
final class DictationHighlight {
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastFrame = CGRect.zero
    private var finishing: Task<Void, Never>?
    /// Counts finish sweeps so the AppKit check can see one without watching pixels.
    private(set) var sweepCount = 0
    var isShown: Bool { panel?.isVisible == true }

    func show(follow frame: @escaping () -> CGRect?) {
        guard let initial = frame() else { return }
        finishing?.cancel(); finishing = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? OutlineView)?.pulse()
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

    /// Verified text lands under an accent sweep, then the outline fades; a hide() during the sweep waits for it.
    func finish(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        timer?.invalidate(); timer = nil
        guard let panel, panel.isVisible, !reduceMotion, let outline = panel.contentView as? OutlineView else {
            panel?.orderOut(nil); return
        }
        sweepCount += 1
        outline.sweep()
        finishing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OutlineView.sweepSeconds))
            guard !Task.isCancelled, let self else { return }
            self.finishing = nil
            self.panel?.orderOut(nil)
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard finishing == nil else { return }
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
    static let sweepSeconds = 0.6
    private let band = CAGradientLayer()
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2.5
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.opacity = 0
        layer?.addSublayer(band)
        pulse()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { layer?.borderColor = NSColor.controlAccentColor.cgColor }

    /// The breathing stroke shown while the shortcut is held and the text is on its way.
    func pulse() {
        guard let layer else { return }
        layer.removeAllAnimations(); band.removeAllAnimations()
        layer.opacity = 1; band.opacity = 0
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0; pulse.toValue = 0.35
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "pulse")
    }

    /// An accent band crosses the field left to right over the new text, then the outline fades out.
    func sweep() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "pulse")
        let accent = NSColor.controlAccentColor
        band.frame = layer.bounds
        band.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.32).cgColor, accent.withAlphaComponent(0).cgColor]
        band.opacity = 1
        band.locations = [1, 1.2, 1.4]
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-0.4, -0.2, 0]; move.toValue = [1, 1.2, 1.4]
        move.duration = 0.4; move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(move, forKey: "sweep")
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0; fade.toValue = 0.0
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.3
        fade.duration = Self.sweepSeconds - 0.3; fade.fillMode = .backwards
        layer.add(fade, forKey: "fade")
    }
}
