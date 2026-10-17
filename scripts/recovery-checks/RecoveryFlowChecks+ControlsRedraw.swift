import Combine
import Foundation
import JotCore
import JotEngine

extension RecoveryFlowChecks {
    /// What a screen that observes only the service shows for Install Update and the shortcut button. SwiftUI reads a screen's values on a later turn of the main actor than objectWillChange, so a change that no publish follows stays on screen.
    @MainActor final class ServiceScreen {
        private(set) var update: Bool
        private(set) var shortcut: Bool
        private let service: SpeechService
        private var redraws: AnyCancellable?
        init(_ service: SpeechService) {
            self.service = service
            update = service.canInstallUpdate; shortcut = service.canChangeShortcut
            redraws = service.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.draw() }
            }
        }
        private func draw() { update = service.canInstallUpdate; shortcut = service.canChangeShortcut }
        /// Lets the redraws the publishes so far scheduled run.
        func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Work that ends with no other change on the service still redraws the controls that wait for it: phrase cleanup that outlasts Pause, a released dictation whose insertion is discarded, and a file diagnostic.
    @MainActor static func checkControlsRedrawWhenWorkEnds(directory: URL) async throws {
        let probe = Probe()
        probe.deliveryFails = false
        let cleanupGate = CleanupGate(), deliveryGate = CleanupGate()
        let store = try TranscriptStore(directory: directory.appendingPathComponent("controls"))
        let service = SpeechService(dependencies: .init(
            infer: { _, job, _ in probe.infer(job) },
            deliver: { _, text in
                try await deliveryGate.pass()
                return try probe.deliver(text)
            },
            now: { probe.now },
            cleanup: { cleaner, texts, timeout in
                await cleaner.cleanWithOutcome(texts, timeout: timeout, generator: { texts in
                    try await cleanupGate.pass()
                    return texts.map { $0.capitalized }
                })
            }, intelligenceAvailability: { .available }))
        service.highlightTargetField = false; service.muteSpeakersDuringDictation = false
        service.keepAudioForSpeakerPass = false; service.cleanUpDictation = false
        service.cleanUpTranscriptions = false
        service.beginRecoveryVerification(store: store, startedAt: probe.now)
        defer { service.shutdown() }
        let screen = ServiceScreen(service)

        // A released hold whose Dictations card is deleted while its text is being inserted.
        service.dictation.begin()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(1), count: 48_000), at: probe.now)
        await service.waitForRecoveryVerification()
        deliveryGate.close()
        service.dictation.end()
        while !deliveryGate.holding { try await Task.sleep(for: .milliseconds(1)) }
        try await screen.settle()
        precondition(!screen.shortcut, "The shortcut button stayed enabled while a released dictation was pending")
        // Deleting the card discards the attempt's rows first, as here.
        service.dictation.discard(ids: [service.dictation.currentAttempt!.id])
        deliveryGate.open()
        await service.waitForRecoveryVerification()
        try await screen.settle()
        // Replacement readiness is read live, as Update's wait reads it: the discard's closing library read can still be on the store queue when isPending's redraw lands, and its end publishes on the library, not the service. In the app, listening keeps replacement blocked through any dictation anyway.
        precondition(!service.dictation.isPending && screen.shortcut && service.canInstallUpdate, "The shortcut and replacement readiness stayed disabled after a dictation discarded during insertion")
        print("PASS: a released dictation discarded during insertion enables the shortcut and replacement readiness again.")

        // What speech.transcribe_file sets and clears around a file diagnostic.
        service.diagnosticActive = true
        try await screen.settle()
        precondition(!screen.update, "App replacement stayed allowed during a file diagnostic")
        service.diagnosticActive = false
        try await screen.settle()
        precondition(screen.update, "App replacement stayed blocked after a file diagnostic")
        print("PASS: app replacement waits for a file diagnostic to end.")

        // Phrase cleanup still running when Pause finishes.
        service.cleanUpTranscriptions = true
        cleanupGate.close()
        probe.now += 3
        service.ingestRecoveryVerification(samples: Array(repeating: Float(2), count: 48_000), at: probe.now)
        service.flushRecoveryVerification()
        while !cleanupGate.holding { try await Task.sleep(for: .milliseconds(1)) }
        service.pause()
        while service.pauseRequested { try await Task.sleep(for: .milliseconds(10)) }
        try await screen.settle()
        precondition(service.cleanup.isRunning && !screen.update, "App replacement was allowed while cleanup was still running after Pause")
        var updateFinished = false
        let update = Task { try await service.prepareForUpdate(); updateFinished = true }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!updateFinished, "Update skipped pending cleanup")
        cleanupGate.open()
        try await update.value
        service.cancelUpdatePreparation()
        try await screen.settle()
        precondition(service.canInstallUpdate && screen.update, "Replacement stayed blocked after cleanup that outlasted Pause finished")
        print("PASS: app replacement waits for cleanup that outlasts Pause.")
    }
}
