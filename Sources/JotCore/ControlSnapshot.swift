import Foundation

/// A cheap, text-free control surface for local menu bars. No history query,
/// transcript, target app, meeting title, session ID or audio crosses this API.
///
/// Version 1 is what `speech.controls` answers by default, so `jot controls` and `jot listen` read the same bytes as
/// before. A caller that sends `{"version": 2}` also gets the version 2 fields; each is left out when it has no value.
public struct ControlSnapshot: Codable, Equatable, Sendable {
    public static let latestVersion = 2

    public let version: Int
    public let mode: String
    public let meetingActive: Bool
    public let dictation: DictationAttempt.State?
    public let dictationSequence: UInt64
    public let suggestion: String
    public let suggestionSequence: Int
    public let inputLevel: Double
    /// Version 2: when the running meeting began, kept through automatic pauses. Nil without a meeting.
    public let meetingStartedAt: Date?
    /// Version 2: a `ControlNotice` raw value saying what Jot's notice is about, never its text. Nil without a notice.
    /// A string rather than the enum, so a reader built before a new code still decodes the snapshot.
    public let notice: String?

    /// Listening is on or starting. Computed, so it never changes the encoded reply.
    public var listening: Bool { ListeningState.listens(mode: mode) }

    /// Version 1 drops the version 2 fields, so a version 1 reply has exactly the version 1 keys.
    public init(version: Int = 1, mode: String, meetingActive: Bool, dictation: DictationAttempt.State?,
                dictationSequence: UInt64, suggestion: String, suggestionSequence: Int, inputLevel: Double,
                meetingStartedAt: Date? = nil, notice: ControlNotice? = nil) {
        let clamped = min(max(version, 1), Self.latestVersion)
        self.version = clamped
        self.mode = mode; self.meetingActive = meetingActive; self.dictation = dictation
        self.dictationSequence = dictationSequence; self.suggestion = suggestion
        self.suggestionSequence = suggestionSequence
        self.inputLevel = inputLevel.isFinite ? min(1, max(0, inputLevel)) : 0
        let v2 = clamped >= 2
        self.meetingStartedAt = v2 && meetingActive ? meetingStartedAt : nil
        self.notice = v2 ? notice?.rawValue : nil
    }

    /// Maps the microphone meter (0 to `MicrophoneSignal.maxLevel`) onto the 0...1 wire level.
    public static func inputLevel(meter: Int) -> Double {
        Double(meter) / Double(MicrophoneSignal.maxLevel)
    }

    /// The version a `speech.controls` request asks for: 1 when it names none.
    public static func requestedVersion(_ params: [String: Any]) throws -> Int {
        guard let value = params["version"] else { return 1 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = Int(exactly: number.doubleValue), (1...latestVersion).contains(version) else {
            throw LocalServiceError.invalid("version must be 1 or \(latestVersion)")
        }
        return version
    }

    /// Reads a `speech.controls` result. The socket writes dates as ISO 8601, so a plain decoder would fail on a meeting.
    public static func decode(_ data: Data) throws -> ControlSnapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlSnapshot.self, from: data)
    }
}

/// What Jot's notice is about, as a short fixed code for hosts like the Island. The notice text itself can hold error
/// messages, file names and meeting names, so it never leaves Jot over the control surface.
public enum ControlNotice: String, CaseIterable, Sendable {
    case modelsLoading = "models.loading"
    case meetingStartFailed = "meeting.start-failed"
    /// End meeting is waiting for cleanup to finish the last words before it exports.
    case meetingExporting = "meeting.exporting"
    /// End meeting was refused or its export failed; Jot's window says why.
    case meetingEndFailed = "meeting.end-failed"
    /// The meeting exported as several files because it was paused along the way.
    case meetingSavedInParts = "meeting.saved-in-parts"
    /// The meeting exported before cleanup finished, so its last lines are as recognized.
    case meetingExportedUncleaned = "meeting.exported-uncleaned"
    /// Pause ended the meeting; its transcript is in Sessions.
    case meetingStopped = "meeting.stopped"
    case pausedForSleep = "paused.sleep"
    case microphoneChanged = "microphone.changed"
    case microphoneStopped = "microphone.stopped"
    /// Any other notice. Hosts may ignore it or offer to open Jot.
    case other
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
