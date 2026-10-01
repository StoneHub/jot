import Foundation

/// One outstanding request with a deadline. A timeout cancels the request, but the gate stays closed until
/// the generator actually returns, so a model that ignores cancellation cannot overlap the next request.
@MainActor
public final class ModelCallGate {
    public typealias Generator = @Sendable (ModelRequest) async throws -> String

    public let deadline: Duration
    public private(set) var outstanding = false
    private var waiters: [OneShotCompletion<Bool>] = []
    private var interrupt: (() -> Void)?

    /// Dismissal releases the caller immediately, but retains the gate until generation actually ends.
    public func cancel() { interrupt?() }

    public init(deadline: Duration = .seconds(2)) {
        self.deadline = deadline
    }

    /// `deadline` overrides the gate's own for one request, such as a longer draft.
    public func call(_ request: ModelRequest, deadline: Duration? = nil, generator: @escaping Generator) async -> ModelCallResult {
        guard !Task.isCancelled else { return .cancelled }
        guard !outstanding else { return .blocked }
        outstanding = true
        let deadline = deadline ?? self.deadline
        return await withCheckedContinuation { continuation in
            let completion = OneShotCompletion(continuation)
            let generation = Task.detached(priority: .userInitiated) { try await generator(request) }
            let work = Task {
                let result: ModelCallResult
                do { result = .output(try await generation.value) }
                catch let error as ModelUnavailable { result = .unavailable(error.reason) }
                catch { result = .failed }
                outstanding = false
                interrupt = nil
                completion.finish(result)
                let settled = waiters
                waiters = []
                for waiter in settled { waiter.finish(true) }
            }
            interrupt = {
                completion.finish(.cancelled)
                generation.cancel()
                work.cancel()
            }
            Task {
                try? await Task.sleep(for: deadline)
                if completion.finish(.timedOut) { generation.cancel(); work.cancel() }
            }
        }
    }

    /// Waits up to `limit` for an outstanding request to return. False means it is still running.
    public func settle(within limit: Duration) async -> Bool {
        guard outstanding else { return true }
        return await withCheckedContinuation { continuation in
            let completion = OneShotCompletion(continuation)
            waiters.append(completion)
            Task {
                try? await Task.sleep(for: limit)
                completion.finish(false)
            }
        }
    }
}
