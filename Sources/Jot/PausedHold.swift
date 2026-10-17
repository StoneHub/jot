import Foundation

/// A hold of the dictation shortcut while Jot is paused with the models loaded. The microphone starts for this hold
/// alone, in a session of its own, and the hold begins when it is up; release stops it and Jot is paused again.
///
/// This object owns only the hold's two pieces of state, the start in flight and whether the microphone is on for the
/// hold. SpeechService keeps the microphone itself, because starting and stopping it changes listening state that only
/// SpeechService may write, and calls `interrupt()` from Pause and `cancelStart()` from shutdown.
@MainActor
final class PausedHold {
    /// The microphone is starting for a hold. A second press is ignored until this settles, even after a release.
    private var start: Task<Void, Never>?
    /// The microphone is on, or starting, for a held dictation only.
    private(set) var isActive = false
    var isStarting: Bool { start != nil }

    private let startMicrophone: @MainActor () async throws -> Void
    private let stopMicrophone: () -> Void
    private let microphoneOn: () -> Bool
    private let beginDictation: () -> Void
    private let report: (Error) -> Void

    init(startMicrophone: @escaping @MainActor () async throws -> Void, stopMicrophone: @escaping () -> Void,
         microphoneOn: @escaping () -> Bool, beginDictation: @escaping () -> Void, report: @escaping (Error) -> Void) {
        self.startMicrophone = startMicrophone
        self.stopMicrophone = stopMicrophone
        self.microphoneOn = microphoneOn
        self.beginDictation = beginDictation
        self.report = report
    }

    /// Starts the microphone for a hold. The dictation begins only if the hold is still wanted once the microphone is up.
    func begin() {
        guard start == nil else { return }
        isActive = true
        start = Task {
            defer { start = nil }
            do {
                try await startMicrophone()
                guard !Task.isCancelled, isActive, microphoneOn() else { stop(); return }
                beginDictation()
            } catch {
                isActive = false
                report(error)
            }
        }
    }

    /// The shortcut came up or a short tap was discarded: a hold-only microphone stops.
    func release() {
        if isActive { stop() }
    }

    /// Pause takes over: the hold ends without stopping the microphone, which Pause stops itself. Returns the start in
    /// flight so Pause can wait for it.
    func interrupt() -> Task<Void, Never>? {
        let pending = start
        pending?.cancel(); isActive = false
        return pending
    }

    /// Quit: only the start in flight is cancelled.
    func cancelStart() { start?.cancel() }

    private func stop() {
        isActive = false
        start?.cancel()
        stopMicrophone()
    }
}
