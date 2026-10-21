import Foundation

/// `transcripts.wait`: one `transcripts.since` page, held until it has something to apply or the timeout passes.
/// It lets an MCP client that cannot run `jot listen` follow speech in one call per change instead of a poll every two seconds.
/// Reads go through the store's change counter, so a waiting client costs one cheap read every `pollSeconds`.
public enum TranscriptWait {
    public static let defaultTimeoutSeconds = 30
    /// Under the two minutes after which Claude Code moves a running tool call to the background.
    public static let maximumTimeoutSeconds = 110
    public static let pollSeconds = 0.5
    /// Waiting clients each hold one of the socket's eight connections, so most stay free for controls and reads.
    public static let maximumWaiters = 2

    public struct Outcome: Sendable {
        public var page: TranscriptChanges
        public var timedOut: Bool
    }

    /// The timeout a request asked for, refused when it is not a whole number of seconds in range.
    public static func timeout(_ params: [String: Any]) throws -> Int {
        guard let value = params["timeoutSeconds"] else { return defaultTimeoutSeconds }
        guard let seconds = value as? Int, (0...maximumTimeoutSeconds).contains(seconds) else {
            throw TranscriptWaitError("timeoutSeconds must be an integer from 0 to \(maximumTimeoutSeconds)")
        }
        return seconds
    }

    /// Reads pages until one has rows, tombstones or a reset, or until `timeout` seconds pass. An omitted cursor subscribes at
    /// the head, so only speech after the call returns. A session filter can advance the cursor over other sessions' changes
    /// without rows; the returned page carries that cursor, so a timed-out page is still the place to resume from.
    public static func run(cursor: Int64?, generation: String?, timeout: Int, now: @Sendable () -> Double,
                           read: @Sendable (Int64?, String?) async throws -> TranscriptChanges,
                           sleep: @Sendable (Double) async throws -> Void) async throws -> Outcome {
        let deadline = now() + Double(timeout)
        var cursor = cursor, generation = generation
        while true {
            let page = try await read(cursor, generation)
            if page.reset || !page.rows.isEmpty || !page.deleted.isEmpty { return Outcome(page: page, timedOut: false) }
            cursor = page.cursor; generation = page.generation ?? generation
            let remaining = deadline - now()
            guard remaining > 0 else { return Outcome(page: page, timedOut: true) }
            if page.hasMore { continue }
            try await sleep(min(pollSeconds, remaining))
        }
    }
}

public struct TranscriptWaitError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
