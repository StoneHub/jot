import Foundation
import JotCore

/// Evaluation owns its cancellation grace period and two-second experiment default.
/// Production ModelCallGate owns actual request exclusion/cancellation only.
@MainActor
final class EvaluationModelGate {
    private let gate: ModelCallGate
    var outstanding: Bool { gate.outstanding }

    init(deadline: Duration = .seconds(2)) { gate = ModelCallGate(deadline: deadline) }
    func call(_ request: ModelRequest, deadline: Duration? = nil, generator: @escaping ModelCallGate.Generator) async -> ModelCallResult {
        await gate.call(request, deadline: deadline, generator: generator)
    }
    func cancel() { gate.cancel() }

    func settle(within limit: Duration) async -> Bool {
        let end = ContinuousClock.now.advanced(by: limit)
        while gate.outstanding {
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: min(remaining, .milliseconds(5))) }
            catch { return false }
        }
        return true
    }
}
