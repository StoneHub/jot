import Foundation

/// When ambient capture keeps running through a long quiet stretch, the next speech belongs to a new session.
public enum SessionSplit {
    /// Minutes of quiet that end a session; 0 keeps one session until capture stops.
    public static let choices = [0, 10, 15, 30]
    public static let defaultMinutes = 15

    /// Measure quiet from the last transcribed row, or from the session start while a session has produced none.
    public static func shouldStart(silenceMinutes: Int, silenceSeconds: TimeInterval, isMeeting: Bool, workPending: Bool) -> Bool {
        guard silenceMinutes > 0, !isMeeting, !workPending, silenceSeconds.isFinite else { return false }
        return silenceSeconds >= Double(silenceMinutes) * 60
    }

    public static func label(_ minutes: Int) -> String {
        minutes == 0 ? "Never" : "\(minutes) minutes"
    }
}
