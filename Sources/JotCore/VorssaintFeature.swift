import Foundation

/// Jot's feature in Vorssaint's Dynamic Island. Vorssaint starts the bundled
/// `jot-vorssaint` helper while the feature is on and exchanges one JSON line
/// per request. Replies carry only what `ControlSnapshot` carries: no
/// transcript, meeting title, target app or audio reaches the host.
public struct VorssaintPresentation: Sendable {
    public static let actions: Set<String> = ["open", "quit", "listen", "pause", "meeting.start", "meeting.end"]

    private var instance = UUID().uuidString
    private var process: Int32?
    private var dictation: (sequence: UInt64, state: DictationAttempt.State?)?
    private var suggestion: (sequence: Int, outcome: String)?
    private var result: (phase: String, status: String, at: Date)?

    public init() {}

    /// The host's view of one snapshot. A new Jot process starts a new
    /// instance, so the host drops prompts opened against the old one.
    public mutating func reply(_ controls: ControlSnapshot, process: Int32, now: Date = Date()) -> [String: Any] {
        if self.process != process { self = VorssaintPresentation(); self.process = process }
        let listening = Self.isListening(controls)
        let meeting = controls.meetingActive
        var phase = "idle"
        var status = meeting ? "Meeting recording" : listening ? "Listening" : "Not listening"
        if controls.dictation == .capturing || meeting {
            phase = "capturing"; status = meeting ? "Meeting recording" : "Capturing"
        } else if controls.dictation == .recognizing {
            phase = "processing"; status = "Processing"
        } else if controls.suggestion == "loading" {
            phase = "processing"; status = "Thinking"
        } else if let last = dictation, (last.sequence != controls.dictationSequence || last.state != controls.dictation),
                  let state = controls.dictation, [.delivered, .deliveryFailed, .deliveryUnverified, .ready].contains(state) {
            // Only a confirmed insertion reads as done; anything else asks for review in Jot.
            phase = state == .delivered ? "completed" : "review"
            status = state == .delivered ? "Inserted" : "Review in Jot"
            result = (phase, status, now)
        } else if let last = suggestion, (last.sequence != controls.suggestionSequence || last.outcome != controls.suggestion),
                  ["ready", "inserted", "insertion-unverified", "selection-unavailable", "insertion-cancelled"].contains(controls.suggestion) {
            phase = controls.suggestion == "inserted" ? "completed" : "review"
            status = controls.suggestion == "ready" ? "Preview ready · Tab"
                : controls.suggestion == "inserted" ? "Inserted" : "Check the text field"
            result = (phase, status, now)
        } else if let result, now.timeIntervalSince(result.at) < 2 {
            phase = result.phase; status = result.status
        }
        dictation = (controls.dictationSequence, controls.dictation)
        suggestion = (controls.suggestionSequence, controls.suggestion)
        return ["version": 1, "instance": instance, "status": status, "phase": phase, "level": controls.inputLevel,
                "toggleValues": ["listening": listening || meeting],
                "enabledActions": ["open", "quit", listening || meeting ? "pause" : "listen",
                                   meeting ? "meeting.end" : "meeting.start"]]
    }

    /// Jot answers pause and resume before capture has finished changing, so
    /// the helper reads again until the snapshot shows what was asked for.
    /// Pause settles only once Jot's icon has: "pausing" still saves speech
    /// and unloads models, so the switch would flip back off early.
    public static func settled(after action: String, _ controls: ControlSnapshot) -> Bool {
        switch action {
        case "listen": isListening(controls) || controls.meetingActive
        case "pause": ["paused", "failed"].contains(controls.mode) && !controls.meetingActive
        case "meeting.start": controls.meetingActive
        case "meeting.end": !controls.meetingActive
        default: true
        }
    }

    private static func isListening(_ controls: ControlSnapshot) -> Bool {
        controls.listening
    }
}
