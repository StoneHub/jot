import Foundation

/// A cheap, text-free control surface for local menu bars. No history query,
/// transcript, target app, meeting title, session ID or audio crosses this API.
public struct ControlSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let mode: String
    public let meetingActive: Bool
    public let dictation: DictationAttempt.State?
    public let dictationSequence: UInt64
    public let suggestion: String
    public let suggestionSequence: Int
    public let inputLevel: Double

    /// Listening is on or starting. Computed, so it never changes the encoded reply.
    public var listening: Bool { ListeningState.listens(mode: mode) }

    public init(mode: String, meetingActive: Bool, dictation: DictationAttempt.State?,
                dictationSequence: UInt64, suggestion: String, suggestionSequence: Int, inputLevel: Double) {
        version = 1
        self.mode = mode; self.meetingActive = meetingActive; self.dictation = dictation
        self.dictationSequence = dictationSequence; self.suggestion = suggestion
        self.suggestionSequence = suggestionSequence
        self.inputLevel = inputLevel.isFinite ? min(1, max(0, inputLevel)) : 0
    }

    /// Maps the microphone meter (0 to `MicrophoneSignal.maxLevel`) onto the 0...1 wire level.
    public static func inputLevel(meter: Int) -> Double {
        Double(meter) / Double(MicrophoneSignal.maxLevel)
    }
}

public enum ControlEvents {
    /// An invalidation hint only. Receivers must read the same-user socket;
    /// distributed notifications are never trusted as state or commands.
    public static let changed = Notification.Name("space.jot.app.controlsChanged")
    public static func signal() {
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil,
            userInfo: nil, deliverImmediately: true)
    }
}
