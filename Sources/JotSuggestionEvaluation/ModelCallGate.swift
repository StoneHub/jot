import Foundation

/// The model reported that it cannot run. `reason` is an AppleFM availability value, never model error text.
struct ModelUnavailable: Error, Equatable {
    let reason: String
}

enum ModelCallResult: Equatable {
    case output(String)
    case unavailable(String)
    case failed
    case timedOut
    /// An earlier request has not returned, so nothing was started.
    case blocked
}

/// One outstanding request with a deadline. A timeout cancels the request, but the gate stays closed until
/// the generator actually returns, so a model that ignores cancellation cannot overlap the next request.
@MainActor
final class ModelCallGate {
    typealias Generator = @Sendable (ModelRequest) async throws -> String

    let deadline: Duration
    private(set) var outstanding = false
    private var waiters: [Completion<Bool>] = []

    init(deadline: Duration = .seconds(2)) {
        self.deadline = deadline
    }

    func call(_ request: ModelRequest, generator: @escaping Generator) async -> ModelCallResult {
        guard !outstanding else { return .blocked }
        outstanding = true
        let deadline = self.deadline
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            let work = Task {
                let result: ModelCallResult
                do { result = .output(try await generator(request)) }
                catch let error as ModelUnavailable { result = .unavailable(error.reason) }
                catch { result = .failed }
                outstanding = false
                completion.finish(result)
                let settled = waiters
                waiters = []
                for waiter in settled { waiter.finish(true) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if completion.finish(.timedOut) { work.cancel() }
            }
        }
    }

    /// Waits up to `limit` for an outstanding request to return. False means it is still running.
    func settle(within limit: Duration) async -> Bool {
        guard outstanding else { return true }
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            waiters.append(completion)
            Task {
                try? await Task.sleep(for: limit)
                completion.finish(false)
            }
        }
    }
}

@MainActor
final class Completion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    @discardableResult func finish(_ value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
