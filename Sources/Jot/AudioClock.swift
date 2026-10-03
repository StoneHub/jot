import Foundation
import JotCore

/// The one sample rate every buffer in the app uses; the recognizer models expect 16 kHz mono.
enum AudioClock {
    static let sampleRate = 16000
    static func samples(seconds: Double) -> Int { Int((seconds * Double(sampleRate)).rounded()) }
    static func seconds(samples: Int) -> Double { Double(samples) / Double(sampleRate) }
}
