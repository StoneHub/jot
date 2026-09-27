import XCTest
@testable import JotCore

final class DictationReadinessTests: XCTestCase {
    private func blocker(phase: ServiceLifecycle.Phase = .ready, modelsReady: Bool = true, ambientEnabled: Bool = true,
                         pauseRequested: Bool = false, dictationPending: Bool = false, dictationActive: Bool = false,
                         diagnosticActive: Bool = false, microphoneStarting: Bool = false) -> String? {
        DictationReadiness.blocker(phase: phase, modelsReady: modelsReady, ambientEnabled: ambientEnabled,
            pauseRequested: pauseRequested, dictationPending: dictationPending, dictationActive: dictationActive,
            diagnosticActive: diagnosticActive, microphoneStarting: microphoneStarting)
    }

    func testReadyServiceHasNoBlocker() {
        XCTAssertNil(blocker())
    }

    func testMicrophoneOffStartsForTheHoldUnlessItIsAlreadyStarting() {
        XCTAssertNil(blocker(ambientEnabled: false), "With the models loaded, a hold while paused starts the microphone")
        XCTAssertEqual(blocker(ambientEnabled: false, microphoneStarting: true), "The microphone is starting. Try again in a moment.")
        XCTAssertNil(blocker(microphoneStarting: true), "A microphone that is already on is not starting")
    }

    func testPausedAndLoadingStatesComeBeforeMicrophone() {
        XCTAssertEqual(blocker(phase: .paused, modelsReady: false, ambientEnabled: false), "Jot is paused. Choose Resume to dictate.")
        XCTAssertEqual(blocker(phase: .failed, modelsReady: false, ambientEnabled: false), "Jot is paused. Choose Resume to dictate.")
        XCTAssertEqual(blocker(phase: .starting, modelsReady: false, ambientEnabled: false), "Jot is still loading. Try again in a moment.")
        XCTAssertEqual(blocker(modelsReady: false, ambientEnabled: false), "Jot is still loading. Try again in a moment.")
        XCTAssertEqual(blocker(phase: .pausing, ambientEnabled: false), "Jot is pausing. Wait for it to finish, then Resume.")
        XCTAssertEqual(blocker(pauseRequested: true), "Jot is pausing. Wait for it to finish, then Resume.")
    }

    func testBusyStatesEachHaveTheirOwnWords() {
        XCTAssertEqual(blocker(diagnosticActive: true), "Wait for the file diagnostic to finish.")
        XCTAssertEqual(blocker(dictationPending: true), "The last dictation is still being inserted. Try again in a moment.")
        XCTAssertEqual(blocker(dictationActive: true), "Dictation is already running.")
    }
}
