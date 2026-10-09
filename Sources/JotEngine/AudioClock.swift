import FluidAudio
import Foundation
import JotCore

/// The one sample rate every buffer in the app uses; the recognizer models expect 16 kHz mono.
public enum AudioClock {
    public static let sampleRate = 16000
    public static func samples(seconds: Double) -> Int { Int((seconds * Double(sampleRate)).rounded()) }
    public static func seconds(samples: Int) -> Double { Double(samples) / Double(sampleRate) }
    /// A whole audio file converted to this rate, mono, for tools that read recordings; FluidAudio stays inside JotEngine.
    public static func resample(_ url: URL) throws -> [Float] { try AudioConverter().resampleAudioFile(url) }
}
