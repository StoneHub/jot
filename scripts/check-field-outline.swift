import AppKit

/// Builds with Sources/Jot/DictationHighlight.swift alone. Checks when the outline shows, sweeps, and hides, not how the sweep looks.
@main struct FieldOutlineChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let field = CGRect(x: 200, y: 200, width: 320, height: 40)
        let outline = DictationHighlight()

        outline.show(follow: { field })
        precondition(outline.isShown, "The outline did not appear over the field")
        outline.finish(reduceMotion: false)
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
        outline.hide()
        precondition(!outline.isShown, "Hide did not remove the outline of a hold with no sweep")
        print("PASS: a hold that starts during the sweep keeps its outline.")

        outline.show(follow: { field })
        outline.finish(reduceMotion: true)
        precondition(!outline.isShown && outline.sweepCount == 2, "Reduce Motion still played the finish sweep")
        print("PASS: Reduce Motion removes the outline without a sweep.")

        var acquired: CGRect?
        outline.show(follow: { acquired })
        precondition(!outline.isShown, "The outline appeared before the field was known")
        try await Task.sleep(for: .seconds(0.3))
        precondition(!outline.isShown, "The outline appeared before the field was known")
        acquired = field
        try await Task.sleep(for: .seconds(0.5))
        precondition(outline.isShown, "The outline never appeared once the field was found after the press")
        acquired = nil
        try await Task.sleep(for: .seconds(0.5))
        precondition(!outline.isShown, "The outline stayed up after the field went away")
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
