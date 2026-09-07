#if !DEBUG
import SwiftUI
import XCTest
@testable import DevFeedback

final class ReleaseExclusionTests: XCTestCase {
    @MainActor
    func testReleaseModifiersDoNotEvaluateTargetMetadata() {
        var evaluated = false
        func metadata() -> String { evaluated = true; return "synthetic-private-target" }
        _ = Text("Host view")
            .feedbackTarget(metadata(), label: metadata())
            .feedbackViewport()
            .feedbackOverlay(appID: metadata(), screen: metadata())
        XCTAssertFalse(evaluated, "Release builds must not compute or register feedback metadata")
    }
}
#endif
