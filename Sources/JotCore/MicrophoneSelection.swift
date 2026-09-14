import Foundation

/// Decides which microphone capture opens from the saved choice and the devices connected right now.
public enum MicrophoneSelection {
    /// nil means System Default. A saved device that is not connected falls back to System Default; the choice itself is kept by the caller.
    public static func captureUID(saved: String?, available: [String]) -> String? {
        guard let saved, !saved.isEmpty, available.contains(saved) else { return nil }
        return saved
    }
}
