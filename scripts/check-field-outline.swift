import AppKit

/// Builds with Sources/Jot/DictationHighlight.swift alone. Checks the real panel and animation lifecycle.
@main struct FieldOutlineChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let field = CGRect(x: 200, y: 200, width: 320, height: 40)
        let outline = DictationHighlight()

        var movingField = field
        outline.show(follow: { movingField })
        let panel = NSApplication.shared.windows.first { $0.isVisible && $0.level == .statusBar }!
        let layer = panel.contentView!.layer!
        let band = layer.sublayers!.first as! CAGradientLayer
        outline.process(reduceMotion: false)
        let loop = band.animation(forKey: "sweep") as! CABasicAnimation
        precondition(loop.autoreverses && loop.repeatCount == .infinity && loop.duration == 0.9,
                     "Release did not turn the existing wash into a back-and-forth loop")
        try await Task.sleep(for: .seconds(3.8))
        precondition(outline.isShown && band.animation(forKey: "sweep") != nil && layer.animation(forKey: "fade") == nil,
                     "Processing faded before recognition and insertion finished")
        movingField.size.width *= 2
        try await Task.sleep(for: .seconds(0.4))
        precondition(band.frame.size == layer.bounds.size, "The processing wash did not follow a resized field")
        precondition(panel.ignoresMouseEvents && !panel.isKeyWindow, "The processing overlay intercepted input or focus")
        outline.hide()
        precondition(!outline.isShown && band.animationKeys() == nil, "Cancellation left the wash running")
        outline.process(reduceMotion: false)
        precondition(!outline.isShown && band.animationKeys() == nil, "Release restarted a hidden or disabled highlight")
        print("PASS: release loops the wash across multiple cycles, follows field resizing, and cancellation stops it without taking focus.")

        outline.show(follow: { field })
        precondition(outline.isShown, "The outline did not appear over the field")
        outline.process(reduceMotion: false)
        outline.finish(reduceMotion: false)
        precondition((band.animation(forKey: "sweep") as! CABasicAnimation).repeatCount == 0,
                     "Verified insertion kept looping the processing wash")
        outline.hide()
        precondition(outline.isShown && outline.sweepCount == 1, "Hiding at the end of the attempt cut off the finish sweep")
        try await Task.sleep(for: .seconds(0.9))
        precondition(!outline.isShown, "The outline stayed up after the finish sweep")
        print("PASS: verified text plays one sweep, a hide during it waits, and the outline leaves when it ends.")

        outline.show(follow: { field })
        outline.finish(reduceMotion: false)
        outline.show(follow: { field })
        try await Task.sleep(for: .seconds(0.9))
        precondition(outline.isShown, "A new hold lost its outline to the previous finish sweep")
        precondition(band.animationKeys() == nil && layer.animation(forKey: "pulse") != nil,
                     "A new hold inherited the previous wash")
        outline.hide()
        precondition(!outline.isShown, "Hide did not remove the outline of a hold with no sweep")
        print("PASS: a hold that starts during the sweep keeps its outline.")

        outline.show(follow: { field })
        outline.process(reduceMotion: true)
        precondition(outline.isShown && band.animationKeys() == nil && layer.animationKeys() == nil,
                     "Reduce Motion did not use a steady processing outline")
        outline.finish(reduceMotion: true)
        precondition(!outline.isShown && outline.sweepCount == 2, "Reduce Motion still played the finish sweep")
        print("PASS: Reduce Motion removes the outline without a sweep.")

        var acquired: CGRect?
        outline.show(follow: { acquired })
        outline.process(reduceMotion: false)
        precondition(!outline.isShown, "The outline appeared before the field was known")
        try await Task.sleep(for: .seconds(0.3))
        precondition(!outline.isShown, "The outline appeared before the field was known")
        acquired = field
        try await Task.sleep(for: .seconds(0.5))
        precondition(outline.isShown, "The outline never appeared once the field was found after the press")
        precondition(band.animation(forKey: "sweep") != nil && band.frame.size == layer.bounds.size,
                     "Late field lookup lost the processing wash")
        acquired = nil
        try await Task.sleep(for: .seconds(0.5))
        precondition(!outline.isShown, "The outline stayed up after the field went away")
        precondition(band.animationKeys() == nil, "Losing the field left the wash running")
        print("PASS: a field found after the press gets its outline, and loses it when the field goes.")

        acquired = nil
        outline.show(follow: { acquired })
        try await Task.sleep(for: .seconds(2.3))
        acquired = field
        try await Task.sleep(for: .seconds(0.5))
        precondition(!outline.isShown, "The outline kept polling a field that never arrived")
        print("PASS: the outline stops looking for a field that never arrives.")
    }
}
