import Foundation

/// Decides which live audio reaches the streaming speaker model. While recognition hears no speech, audio is held back instead of fed, so a quiet room runs no speaker inference. When speech is heard, the held audio goes to the model first, in order, so the model hears exactly what it would have heard.
///
/// Only the most recent `holdSeconds` stay held. Older quiet audio is skipped in whole speaker frames, which keeps the model's frame grid on the session clock; `sessionFrame(forModelFrame:)` maps each model frame back to its place in the session. The hold is longer than both the audio any committed word can reach back to and the model's own recent-audio queue, so words are attributed from the same nearby audio as before, and the model keeps its speaker memory across the skipped quiet.
public struct SpeakerModelFeed: Equatable, Sendable {
    /// Where skipped audio shifts the model's frames: model frames from `modelFrame` on sit `shift` frames later in the session.
    struct Shift: Equatable, Sendable {
        let modelFrame: Int
        let shift: Int
    }

    public let frameSamples: Int
    public let holdSamples: Int
    private(set) var held: [Float] = []
    private var fedSamples = 0
    private var shifts: [Shift] = []
    /// Skip points further back than this can no longer be reported by the model, so they are forgotten.
    private let retainedFrames: Int

    /// - Parameters:
    ///   - frameSeconds: the speaker model's output frame; Sortformer reports one per 0.08 seconds.
    ///   - holdSeconds: quiet audio kept for the model in case speech follows.
    public init(sampleRate: Int = 16_000, frameSeconds: Double = 0.08, holdSeconds: Double = 5) {
        frameSamples = max(1, Int((Double(sampleRate) * frameSeconds).rounded()))
        holdSamples = max(frameSamples, Int((Double(sampleRate) * holdSeconds).rounded()))
        retainedFrames = max(250, 4 * holdSamples / frameSamples)
    }

    /// Quiet audio the model has not heard yet.
    public var heldSampleCount: Int { held.count }

    /// Quiet audio the model will never hear.
    public var skippedSamples: Int { (shifts.last?.shift ?? 0) * frameSamples }

    /// Holds quiet audio back from the model, skipping whole frames of the oldest held audio once more than the hold is waiting.
    public mutating func holdQuiet(_ samples: [Float]) {
        held.append(contentsOf: samples)
        let excess = held.count - holdSamples
        guard excess > 0 else { return }
        let skipFrames = (excess + frameSamples - 1) / frameSamples
        held.removeFirst(skipFrames * frameSamples)
        // Frames that start at or after the next fed sample come from audio after the skip.
        let modelFrame = (fedSamples + frameSamples - 1) / frameSamples
        let total = (shifts.last?.shift ?? 0) + skipFrames
        if shifts.last?.modelFrame == modelFrame { shifts.removeLast() }
        shifts.append(Shift(modelFrame: modelFrame, shift: total))
    }

    /// Speech was heard: returns the held audio followed by `samples`, which is everything the model has not heard, in order.
    public mutating func releaseForSpeech(_ samples: [Float]) -> [Float] {
        let released = held.isEmpty ? samples : held + samples
        held.removeAll(keepingCapacity: true)
        fedSamples += released.count
        let oldest = fedSamples / frameSamples - retainedFrames
        while shifts.count > 1, shifts[1].modelFrame <= oldest { shifts.removeFirst() }
        return released
    }

    /// The session frame, counted from the model's first sample, of a frame the model reports.
    public func sessionFrame(forModelFrame frame: Int) -> Int {
        guard let shift = shifts.last(where: { $0.modelFrame <= frame }) else { return frame }
        return frame + shift.shift
    }

    /// Starts over with the model, as when a session changes or audio is discontinuous.
    public mutating func reset() {
        held.removeAll(keepingCapacity: false)
        fedSamples = 0
        shifts.removeAll(keepingCapacity: false)
    }
}
