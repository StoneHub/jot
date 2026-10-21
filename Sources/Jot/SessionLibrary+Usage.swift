import Foundation
import JotCore

extension SessionLibrary {
    /// Adds to the local usage counters in submission order with the store's other writes, without waiting. A failed
    /// count is dropped: counters never hold up or fail dictation, cleanup or suggestions.
    func countUsage(_ counters: [UsageCounter]) {
        guard let store, !counters.isEmpty else { return }
        let date = Date()
        _ = storeExecutor.submit { try? store.countUsage(counters, at: date) }
    }
}
