#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import DevFeedback

final class FeedbackTargetTests: XCTestCase {
    func testClippedRowsCannotBePickedOverHeaderAndKeepCaptureBounds() throws {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 200)
        let original = CGRect(x: 10, y: 80, width: 100, height: 40)
        let row = try XCTUnwrap(VisibleFeedbackTarget(id: UUID(),
            target: FeedbackTarget(id: "row.mode", label: "Mode", file: "View.swift", line: 1),
            bounds: original, viewports: [viewport]))
        XCTAssertEqual(row.visibleBounds, CGRect(x: 10, y: 100, width: 100, height: 20))
        XCTAssertEqual(row.sourceBounds, original)
        XCTAssertNil(VisibleFeedbackTarget.pick(at: CGPoint(x: 20, y: 90), from: [row]))
        XCTAssertEqual(VisibleFeedbackTarget.pick(at: CGPoint(x: 20, y: 110), from: [row])?.target.id, "row.mode")
        XCTAssertNil(VisibleFeedbackTarget(id: UUID(), target: row.target,
            bounds: CGRect(x: 10, y: 20, width: 100, height: 40), viewports: [viewport]))
        XCTAssertNil(VisibleFeedbackTarget(id: UUID(), target: row.target,
            bounds: original, viewports: [viewport, CGRect(x: 200, y: 100, width: 100, height: 100)]))
    }

    @MainActor
    func testViewportAppliesOnlyToDescendantsAndAccumulatesForNestedClips() {
        var clips: [String: Int] = [:]
        let content = VStack {
            Text("Header").feedbackTarget("header")
            VStack {
                Text("Outer row").feedbackTarget("outer")
                Text("Nested row").feedbackTarget("inner").feedbackViewport()
            }.feedbackViewport()
        }.overlayPreferenceValue(TargetPreference.self) { targets in
            let _ = { clips = Dictionary(uniqueKeysWithValues: targets.map { ($0.target.id, $0.viewports.count) }) }()
            Color.clear
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.close() }
        XCTAssertEqual(clips, ["header": 0, "outer": 1, "inner": 2])
    }

    @MainActor
    func testTaggingAContainerPreservesItsGranularDescendants() throws {
        var observed: Set<String> = []
        let content = VStack {
            Text("Synthetic mode").feedbackTarget("row.mode")
            Text("Synthetic body").feedbackTarget("row.body")
        }
        .feedbackTarget("row")
        .overlayPreferenceValue(TargetPreference.self) { targets in
            let _ = { observed = Set(targets.map { $0.target.id }) }()
            Color.clear
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.close() }
        XCTAssertEqual(observed, ["row", "row.mode", "row.body"])
    }
}
#endif
