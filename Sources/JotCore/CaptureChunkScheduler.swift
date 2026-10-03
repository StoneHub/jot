import Foundation

/// Bounded recognition chunks keep capture latency independent of how long Jot has
/// been listening. A sufficiently long silence may close a shorter chunk.
public struct CaptureChunkScheduler: Equatable, Sendable {
    /// The code defaults; `JotSettings` reads the two the user can change from here.
    public static let defaultMaximumSeconds = 3.0
    public static let defaultMinimumSeconds = 0.2
    public static let defaultSilenceSeconds = 0.7
    public let maximumSamples: Int
    public let minimumSamples: Int
    public let silenceSamples: Int

    public init(sampleRate: Int = 16_000, maximumSeconds: Double = Self.defaultMaximumSeconds,
                minimumSeconds: Double = Self.defaultMinimumSeconds, silenceSeconds: Double = Self.defaultSilenceSeconds) {
        maximumSamples = max(1, Int((Double(sampleRate) * maximumSeconds).rounded()))
        minimumSamples = max(1, Int((Double(sampleRate) * minimumSeconds).rounded()))
        silenceSamples = max(1, Int((Double(sampleRate) * silenceSeconds).rounded()))
    }

    public func shouldFlush(bufferedSamples: Int, consecutiveSilentSamples: Int) -> Bool {
        bufferedSamples >= maximumSamples ||
            (bufferedSamples >= minimumSamples && consecutiveSilentSamples >= silenceSamples)
    }

    /// Splits an overdue buffer without dropping the tail. The caller can enqueue
    /// every complete chunk and keep the remainder for the next microphone drain.
    public func split(_ samples: [Float]) -> (chunks: [[Float]], remainder: [Float]) {
        guard samples.count >= maximumSamples else { return ([], samples) }
        var chunks: [[Float]] = []
        var start = 0
        while samples.count - start >= maximumSamples {
            chunks.append(Array(samples[start..<(start + maximumSamples)]))
            start += maximumSamples
        }
        return (chunks, Array(samples[start...]))
    }
}
