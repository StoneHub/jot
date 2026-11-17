import Foundation

/// One look at whether the field Jot captured still has focus.
///
/// An app that is slow to answer is not the same as focus moving. Safari's web content can take longer than Jot's 5 ms
/// focus read while it lays out text Jot has just written, and treating that silence as a focus change dropped real
/// dictation into web pages. So silence is asked again for a short while, and is still never written into; an answer
/// that names another element, or another app in front, ends the delivery at once.
public enum FocusCheck: Equatable, Sendable {
    /// The captured field still has focus in the app in front.
    case current
    /// Another app is in front, nothing has focus, or the focused element is another one.
    case moved
    /// The app did not answer within the read's timeout.
    case noAnswer

    /// Reads at most `attempts` times, waiting between reads while the app gives no answer. Returns the first answer,
    /// or `.noAnswer` when the app stayed silent throughout; a thrown error ends the wait.
    @MainActor
    public static func settle(attempts: Int, wait: () async throws -> Void,
                              read: () throws -> FocusCheck) async throws -> FocusCheck {
        var result = try read()
        var remaining = attempts - 1
        while result == .noAnswer, remaining > 0 {
            try await wait()
            result = try read()
            remaining -= 1
        }
        return result
    }
}
