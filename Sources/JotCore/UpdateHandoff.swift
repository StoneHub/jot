import Foundation

/// What an app update hands to the next launch, and how a failed update gives listening back. The service decides when
/// capture has settled; this keeps whether listening was on when the update began, and writes the handoff to preferences
/// only once the app may be replaced.
@MainActor
public final class UpdateHandoff {
    private let defaults: UserDefaults
    /// Listening was on when the update began, so the relaunch, or a failed update, resumes it.
    public private(set) var resumesListening = false
    private var recovery: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func begin(listening: Bool) { resumesListening = listening }

    /// Capture has settled and the app may be replaced. The next launch resumes only the listening the update
    /// interrupted, including its meeting title.
    public func commit(meetingTitle: String?) {
        defaults.set(!resumesListening, forKey: JotDefaultsKey.servicePaused)
        if resumesListening, let meetingTitle {
            defaults.set(meetingTitle, forKey: JotDefaultsKey.updateMeetingTitle)
        } else { defaults.removeObject(forKey: JotDefaultsKey.updateMeetingTitle) }
    }

    /// The update failed, so the running app stays in charge. Listening it interrupted resumes once the Pause that
    /// `pausing` returns has settled, since a timeout can occur while Pause still drains, unless `stillWanted` is false by
    /// then or `cancelRecovery` ran. `pausing` is read when the resume starts, not when the update is cancelled.
    public func cancel(after pausing: @escaping @MainActor () -> Task<Void, Never>?,
                       stillWanted: @escaping @MainActor () -> Bool, resume: @escaping @MainActor () -> Void) {
        defaults.removeObject(forKey: JotDefaultsKey.updateMeetingTitle)
        guard resumesListening else { return }
        recovery?.cancel()
        recovery = Task { [weak self] in
            if let pausing = pausing() { await pausing.value }
            guard !Task.isCancelled, stillWanted() else { return }
            resume()
            self?.recovery = nil
        }
    }

    /// An explicit Pause or shutdown: a failed update's resume no longer applies.
    public func cancelRecovery() {
        recovery?.cancel()
        recovery = nil
    }

    /// The failed update's resume, for callers that need it to finish.
    public func waitForRecovery() async { await recovery?.value }

    /// Read once at launch and forgotten, so only the relaunch after an update continues its meeting.
    public func takeMeetingTitle() -> String? {
        let title = defaults.string(forKey: JotDefaultsKey.updateMeetingTitle)
        defaults.removeObject(forKey: JotDefaultsKey.updateMeetingTitle)
        return title
    }
}
