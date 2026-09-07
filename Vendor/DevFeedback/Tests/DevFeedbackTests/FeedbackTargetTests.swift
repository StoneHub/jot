#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import DevFeedback

final class FeedbackTargetTests: XCTestCase {
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
