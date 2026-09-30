import Foundation

/// Runs blocking database work in submission order on a dedicated thread pool queue.
/// Operations finish even if their caller is cancelled: cancelling a screen must not
/// cancel a write it already submitted. Callers validate a read's identity before display.
public final class StoreExecutor: @unchecked Sendable {
    // The queue is immutable and is the sole owner of submitted execution. The
    // operation and its result cross the queue only through Sendable values.
    private let queue: DispatchQueue
    private let pendingLock = NSLock()
    private var pending = 0

    /// Includes queued and currently executing work, for safe app replacement.
    public var pendingCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    public init(label: String = "Jot.store") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await submit(operation).value
    }

    /// Enqueues immediately, before returning to a key or UI callback. This lets
    /// saves and deletes share a precise submission order without blocking that callback.
    public func submit<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) -> StoreOperation<Value> {
        let result = StoreOperation<Value>()
        pendingLock.lock()
        pending += 1
        pendingLock.unlock()
        queue.async { [self] in
            let value = Result(catching: operation)
            pendingLock.lock()
            pending -= 1
            pendingLock.unlock()
            result.finish(value)
        }
        return result
    }

    /// Waits for operations already submitted, including writes with cancelled callers.
    public func flush() async {
        _ = try? await perform { () }
    }
}
