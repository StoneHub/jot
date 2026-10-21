import XCTest
@testable import JotCore

final class ControlProjectionTests: XCTestCase {
    func testProjectionPrefersAHeldDictationThenRecognitionThenTheLastAttempt() {
        func phase(active: Bool, pending: Bool, last: DictationAttempt.State?) -> DictationAttempt.State? {
            ControlProjection.controls(mode: "ambient", meetingActive: false, dictationActive: active, dictationPending: pending,
                lastAttempt: last, dictationSequence: 1, suggestion: [:], inputLevel: 0).dictation
        }
        XCTAssertEqual(phase(active: true, pending: true, last: .delivered), .capturing)
        XCTAssertEqual(phase(active: false, pending: true, last: .delivered), .recognizing)
        XCTAssertEqual(phase(active: false, pending: false, last: .deliveryFailed), .deliveryFailed)
        XCTAssertNil(phase(active: false, pending: false, last: nil))
    }

    func testProjectionReadsTheSuggestionOutcomeAndCountWithIdleDefaults() {
        let busy = ControlProjection.controls(mode: "dictation", meetingActive: true, dictationActive: false, dictationPending: false,
            lastAttempt: nil, dictationSequence: 4, suggestion: ["outcome": "loading", "requests": 3, "visible": true], inputLevel: 0.25)
        XCTAssertEqual(busy, ControlSnapshot(mode: "dictation", meetingActive: true, dictation: nil, dictationSequence: 4,
            suggestion: "loading", suggestionSequence: 3, inputLevel: 0.25))
        let quiet = ControlProjection.controls(mode: "paused", meetingActive: false, dictationActive: false, dictationPending: false,
            lastAttempt: nil, dictationSequence: 0, suggestion: [:], inputLevel: 0)
        XCTAssertEqual(quiet.suggestion, "idle")
        XCTAssertEqual(quiet.suggestionSequence, 0)
    }
}
