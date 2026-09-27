import XCTest
@testable import JotCore

/// Maps the service's former listening flags to the state that replaced them. `mode` and `models` are the strings `jot status` reported before the enum: `mode` from the old `updateMode()`, and `models` from the stored model state each transition set alongside the phase.
final class ListeningStateTests: XCTestCase {
    private struct Row {
        let phase: ServiceLifecycle.Phase
        let generation: UInt64
        let microphoneOn: Bool
        let dictationActive: Bool
        let state: ListeningState
        let mode: String
        let models: String
    }

    private let table: [Row] = [
        // Launch: never resumed.
        Row(phase: .paused, generation: 0, microphoneOn: false, dictationActive: false, state: .paused(neverLoaded: true), mode: "paused", models: "not loaded"),
        // After any Pause finishes.
        Row(phase: .paused, generation: 2, microphoneOn: false, dictationActive: false, state: .paused(neverLoaded: false), mode: "paused", models: "unloaded"),
        // Resume loading models.
        Row(phase: .starting, generation: 1, microphoneOn: false, dictationActive: false, state: .starting, mode: "starting", models: "preparing"),
        // Models loaded, microphone not started or failed to start.
        Row(phase: .ready, generation: 1, microphoneOn: false, dictationActive: false, state: .ready, mode: "ready", models: "ready"),
        // Listening.
        Row(phase: .ready, generation: 1, microphoneOn: true, dictationActive: false, state: .listening, mode: "ambient", models: "ready"),
        // A held dictation wins over listening, as updateMode() checked it first.
        Row(phase: .ready, generation: 1, microphoneOn: true, dictationActive: true, state: .dictating, mode: "dictation", models: "ready"),
        Row(phase: .ready, generation: 3, microphoneOn: false, dictationActive: true, state: .dictating, mode: "dictation", models: "ready"),
        // Pause unloading models; the microphone flag is cleared in the same step, but either value maps the same.
        Row(phase: .pausing, generation: 2, microphoneOn: false, dictationActive: false, state: .unloading, mode: "pausing", models: "unloading"),
        Row(phase: .pausing, generation: 2, microphoneOn: true, dictationActive: false, state: .unloading, mode: "pausing", models: "unloading"),
        // Resume failed.
        Row(phase: .failed, generation: 1, microphoneOn: false, dictationActive: false, state: .failed, mode: "failed", models: "failed"),
    ]

    func testFormerFlagsMapToOneState() {
        for row in table {
            let state = ListeningState(phase: row.phase, generation: row.generation, microphoneOn: row.microphoneOn, dictationActive: row.dictationActive)
            XCTAssertEqual(state, row.state, "\(row.phase) g\(row.generation) mic \(row.microphoneOn) dictation \(row.dictationActive)")
            XCTAssertEqual(state.mode, row.mode, "mode for \(row.state)")
            XCTAssertEqual(state.models.rawValue, row.models, "models for \(row.state)")
        }
    }

    /// The former checks, written against the old flags, agree with the state's.
    func testDerivedChecksMatchTheFormerFlagChecks() {
        for row in table {
            let state = ListeningState(phase: row.phase, generation: row.generation, microphoneOn: row.microphoneOn, dictationActive: row.dictationActive)
            let formerPaused = row.phase == .paused || row.phase == .pausing || row.phase == .failed
            let formerChanging = row.phase == .starting || row.phase == .pausing
            let formerModelsReady = row.models == ListeningState.Models.ready.rawValue
            // canHoldDictation: phase ready, models ready, microphone on.
            let formerHold = row.phase == .ready && formerModelsReady && row.microphoneOn
            // microphoneOff: phase ready, microphone off, no dictation.
            let formerMicrophoneOff = row.phase == .ready && !row.microphoneOn && !row.dictationActive
            XCTAssertEqual(state.isPaused, formerPaused, "isPaused for \(row.state)")
            XCTAssertEqual(state.isChanging, formerChanging, "isChanging for \(row.state)")
            XCTAssertEqual(state.modelsLoaded, formerModelsReady, "modelsLoaded for \(row.state)")
            XCTAssertEqual(state.isListening && row.microphoneOn, formerHold, "hold for \(row.state)")
            XCTAssertEqual(state == .ready, formerMicrophoneOff, "microphoneOff for \(row.state)")
        }
    }

    /// Every phase appears in the table, so a new phase cannot go unmapped.
    func testTableCoversEveryPhase() {
        let phases: [ServiceLifecycle.Phase] = [.paused, .starting, .ready, .pausing, .failed]
        for phase in phases { XCTAssertTrue(table.contains { $0.phase == phase }, "\(phase) has no row") }
    }
}
