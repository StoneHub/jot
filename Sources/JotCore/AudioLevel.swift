import Accelerate

/// Microphone level over short windows, on the same RMS scale as the capture's quiet gate.
public enum AudioLevel {
    /// One tenth of a second at the 16 kHz recognition rate: short enough that a single syllable lifts its window above a quiet room.
    public static let windowSamples = 1_600

    /// The loudest window's RMS, so a short word in a long quiet block still counts as sound. Zero for no samples.
    public static func loudestWindowRMS(_ samples: [Float], windowSamples: Int = windowSamples) -> Float {
        guard !samples.isEmpty else { return 0 }
        let size = max(1, windowSamples)
        var loudest: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let count = min(size, buffer.count - start)
                var rms: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &rms, vDSP_Length(count))
                loudest = max(loudest, rms)
                start += count
            }
        }
        return loudest
    }
}
