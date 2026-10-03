import Foundation
import JotCore

@MainActor
func waitForModelGate(_ gate: ModelCallGate, within limit: Duration) async -> Bool {
    let end = ContinuousClock.now.advanced(by: limit)
    while gate.outstanding {
        guard ContinuousClock.now < end else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
