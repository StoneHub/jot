import Foundation

/// Cancellation may arrive before the continuation is installed. Remember it while keeping completion on the main
/// actor, where the same one-shot helper arbitrates the value, deadline and cancellation.
@MainActor
final class OptionalContextWait<Value: Sendable> {
    private var completion: OneShotCompletion<Value?>?
    private var cancelled = false

    func cancel() {
        cancelled = true
        completion?.finish(nil)
    }

    func value(of task: Task<Value, Never>, within limit: Duration) async -> Value? {
        await withCheckedContinuation { continuation in
            let completion = OneShotCompletion<Value?>(continuation)
            self.completion = completion
            guard !cancelled, !Task.isCancelled else { completion.finish(nil); task.cancel(); return }
            Task {
                let value = await task.value
                completion.finish(value)
            }
            Task {
                try? await Task.sleep(for: limit)
                if completion.finish(nil) { task.cancel() }
            }
        }
    }
}
