/// Microphone level over short windows, on the same RMS scale as the capture's quiet gate.
public enum AudioLevel {
    /// One tenth of a second at the 16 kHz recognition rate: short enough that a single syllable lifts its window above a quiet room.
    public static let windowSamples = 1_600

    /// The loudest RMS over every window of `windowSamples`, one sample apart, so a short word reads at its own level wherever
    /// it falls in the block. Half-length windows at both ends keep a word cut off by the block's edge from being averaged
    /// with audio that is not there. Zero for no samples.
    public static func loudestWindowRMS(_ samples: [Float], windowSamples: Int = windowSamples) -> Float {
        guard !samples.isEmpty else { return 0 }
        let size = min(max(1, windowSamples), samples.count)
        var sum = 0.0, loudest = 0.0
        for index in samples.indices {
            let value = Double(samples[index])
            sum += value * value
            if index >= size {
                let leaving = Double(samples[index - size])
                sum -= leaving * leaving
            }
            if index >= size - 1 { loudest = max(loudest, sum / Double(size)) }
        }
        let edge = max(1, size / 2)
        for range in [0..<edge, (samples.count - edge)..<samples.count] {
            loudest = max(loudest, samples[range].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(edge))
        }
        return Float(max(0, loudest).squareRoot())
    }
}
