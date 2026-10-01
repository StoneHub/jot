import AppKit

/// A click-through outline over the field being dictated into, shown from the shortcut press until the text is inserted.
/// The panel never activates, so the target keeps keyboard focus, and it follows the field if it moves.
@MainActor
final class DictationHighlight {
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastFrame = CGRect.zero
    private var finishing: Task<Void, Never>?
    /// Two seconds of 0.2 s ticks, well past the shortcut's own field lookup.
    static let waitTicks = 10
    /// Counts finish sweeps so the AppKit check can see one without watching pixels.
    private(set) var sweepCount = 0
    var isShown: Bool { panel?.isVisible == true }

    /// The shortcut finds its field off the main thread, so the frame is often nil at the press. The outline appears once it is known,
    /// and stops looking after `waitTicks` so a target app that never answers does not keep stalling the main thread.
    func show(follow frame: @escaping () -> CGRect?) {
        finishing?.cancel(); finishing = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? OutlineView)?.pulse()
        if let initial = frame() {
            place(panel, around: initial)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        timer?.invalidate()
        var misses = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                guard let current = frame() else {
                    misses += 1
                    if panel.isVisible || misses >= Self.waitTicks { self.hide() }
                    return
                }
                if !panel.isVisible {
                    self.place(panel, around: current)
                    panel.orderFrontRegardless()
                } else if current != self.lastFrame { self.place(panel, around: current) }
            }
        }
    }

    /// Key release keeps the existing wash moving until recognition, cleanup and insertion finish.
    /// This also works before the asynchronous field lookup has supplied its frame.
    func process(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard timer != nil, finishing == nil else { return }
        (panel?.contentView as? OutlineView)?.process(reduceMotion: reduceMotion)
    }

    /// Verified text lands under an accent sweep, then the outline fades; a hide() during the sweep waits for it.
    func finish(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        timer?.invalidate(); timer = nil
        guard let panel, panel.isVisible, !reduceMotion, let outline = panel.contentView as? OutlineView else {
            hide(); return
        }
        sweepCount += 1
        outline.sweep()
        finishing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(OutlineView.sweepSeconds))
            guard !Task.isCancelled, let self else { return }
            self.finishing = nil
            self.hide()
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard finishing == nil else { return }
        (panel?.contentView as? OutlineView)?.stop()
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = bounds
        CATransaction.commit()
    }

    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAllAnimations()
        band.removeAllAnimations()
        layer?.opacity = 1
        band.opacity = 0
        CATransaction.commit()
    }

    /// The breathing stroke shown while the shortcut is held.
    func pulse() {
        guard let layer else { return }
        stop()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0; pulse.toValue = 0.35
        pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "pulse")
    }

    func process(reduceMotion: Bool) {
        stop()
        if !reduceMotion { sweep(loop: true) }
    }

    /// An accent band crosses the field left to right over the new text, then the outline fades out.
    /// Processing reuses the same band and path, reversing each crossing until delivery ends.
    func sweep(loop: Bool = false) {
        guard let layer else { return }
        stop()
        let accent = NSColor.controlAccentColor
        band.frame = layer.bounds
        band.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.32).cgColor, accent.withAlphaComponent(0).cgColor]
        band.opacity = 1
        band.locations = [1, 1.2, 1.4]
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-0.4, -0.2, 0]; move.toValue = [1, 1.2, 1.4]
        move.duration = loop ? 0.9 : 0.4
        move.autoreverses = loop
        move.repeatCount = loop ? .infinity : 0
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(move, forKey: "sweep")
        if loop { return }
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0; fade.toValue = 0.0
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.3
        fade.duration = Self.sweepSeconds - 0.3; fade.fillMode = .backwards
        layer.add(fade, forKey: "fade")
    }
}
