import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import JotEngine

/// Injectable seams for the agent-runnable recovery harness. Production still uses
/// the real local pipeline and accessibility delivery; no socket or product UI is
/// involved in synthetic verification.
struct SpeechServiceDependencies: Sendable {
    var infer: @MainActor (SpeechPipeline, AudioJob, TranscriptionTuning) async throws -> SpeechOutput
    var deliver: @MainActor (DictationInput, String) async throws -> DictationInput.DeliveryResult
    var now: @MainActor () -> Date
    var cleanup: @MainActor (TranscriptCleanup, [String], Duration) async -> CleanupResult = { cleaner, texts, timeout in
        await cleaner.cleanWithOutcome(texts, timeout: timeout)
    }
    var intelligenceAvailability: @MainActor () -> CleanupAvailability = { TranscriptCleanup.availability }
    var makeMicrophone: @MainActor () -> MicrophoneSource = { MicrophoneCapture() }
    var microphoneRetry = MicrophoneStartRetry()
    var availableInputs: @MainActor () -> [AudioInputDevice] = AudioInputDevice.available
    var defaultInputUID: @MainActor () -> String? = AudioInputDevice.defaultUID
    var prepareModels: @MainActor (SpeechPipeline) async throws -> Void = { try await $0.prepare() }
    var unloadModels: @MainActor (SpeechPipeline) async -> Void = { await $0.unload() }
    var microphoneAuthorization: @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophoneAccess: @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }

    static let live = SpeechServiceDependencies(
        infer: { pipeline, job, tuning in try await pipeline.infer(job, tuning: tuning) },
        deliver: { input, text in try await input.insert(text) },
        now: Date.init)
}
