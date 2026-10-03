import Foundation

/// One outstanding request with a deadline. A timeout cancels the request, but the gate stays closed until
/// the generator actually returns, so a model that ignores cancellation cannot overlap the next request.
@MainActor
public final class ModelCallGate {
    public typealias Generator = @Sendable (ModelRequest) async throws -> String

    public let deadline: Duration
    public private(set) var outstanding = false
    private var interrupt: (() -> Void)?

    /// Dismissal releases the caller immediately, but retains the gate until generation actually ends.
    public func cancel() { interrupt?() }

    public init(deadline: Duration) {
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


}
extension ModelCallGate {
    /// A task's value, or nil once the deadline passes or the caller is cancelled. Optional context never keeps a
    /// dismissed request alive, and a native capture that ignores cancellation cannot deliver a late image.
    public static func value<Value: Sendable>(of task: Task<Value, Never>, within limit: Duration) async -> Value? {
        guard !Task.isCancelled else { task.cancel(); return nil }
        let wait = OptionalContextWait<Value>()
        let value = await withTaskCancellationHandler {
            await wait.value(of: task, within: limit)
        } onCancel: {
            task.cancel()
            Task { @MainActor in wait.cancel() }
        }
        return Task.isCancelled ? nil : value
    }
}
