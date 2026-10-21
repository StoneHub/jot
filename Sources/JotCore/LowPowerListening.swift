import Foundation

/// How listening eases off while macOS Low Power Mode is on: fewer microphone drains, longer recognition chunks,
/// and no cleanup of live rows (Apple Intelligence or a custom model), so live text arrives a little later and stays as recognized.
/// Held dictation and its cleanup are unchanged.
public enum LowPowerListening {
    public static let tickSeconds = 0.5
    public static let chunkMaximumSeconds = 6.0

    public static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Seconds between microphone drains. The microphone queue holds 8 seconds, so half a second loses nothing.
    public static func tickInterval(_ normal: TimeInterval, lowPower: Bool = isOn) -> TimeInterval {
        lowPower ? max(normal, tickSeconds) : normal
    }

    /// Longest recognition chunk. Each chunk re-reads context from the one before, so longer chunks recognize the same speech for less work.
    public static func chunkMaximumSeconds(_ setting: Double, lowPower: Bool = isOn) -> Double {
        lowPower ? max(setting, chunkMaximumSeconds) : setting
    }
}
