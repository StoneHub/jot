import Foundation

/// A slow recognizer must never turn a pending meeting into a completed export.
@MainActor
public enum MeetingExportWait {
    public static func wait(
        isValid: () -> Bool,
        isComplete: () -> Bool,
        sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard isValid() else { throw CancellationError() }
            if isComplete() { return }
            try await sleep()
        }
    }
}
