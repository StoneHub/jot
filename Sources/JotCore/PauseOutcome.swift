import Foundation

/// What a pause leaves for Resume. Sleep, an input change, and stalled input pause
/// automatically and keep listening intent; the Pause button clears it and ends a meeting.
public struct PauseOutcome: Equatable, Sendable {
    public let ambientRequested: Bool
    public let meetingTitle: String?
    /// True when the Pause button ended a running meeting, so the notice can say where its transcript went.
    public let endedMeeting: Bool
    public init(automatic: Bool, ambientRequested: Bool, meetingTitle: String?) {
        self.ambientRequested = automatic && ambientRequested
        self.meetingTitle = automatic ? meetingTitle : nil
        endedMeeting = !automatic && meetingTitle != nil
    }
}
