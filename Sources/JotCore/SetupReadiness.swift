import Foundation

/// The live state behind the pages that have a requirement. Setup keeps no copy of it: the window reads the service each time.
public struct SetupReadiness: Equatable, Sendable {
    public var modelsReady: Bool
    public var microphoneAllowed: Bool
    public var accessibilityAllowed: Bool

    public init(modelsReady: Bool, microphoneAllowed: Bool, accessibilityAllowed: Bool) {
        self.modelsReady = modelsReady; self.microphoneAllowed = microphoneAllowed; self.accessibilityAllowed = accessibilityAllowed
    }

    /// The earliest page whose requirement is unmet now, such as a permission revoked since setup or a download that stopped.
    public var firstUnmet: SetupStep? {
        if !modelsReady { return .models }
        if !microphoneAllowed { return .microphone }
        if !accessibilityAllowed { return .dictation }
        return nil
    }
}
