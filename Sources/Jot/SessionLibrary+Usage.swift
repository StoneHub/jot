import Foundation
import JotCore
import JotEngine

extension SessionLibrary {
    /// Adds to the local usage counters in submission order with the store's other writes, without waiting. A failed
    /// count is dropped: counters never hold up or fail dictation, cleanup or suggestions.
    func countUsage(_ counters: [UsageCounter]) {
        guard let store, !counters.isEmpty else { return }
        let date = Date()
        _ = storeExecutor.submit { try? store.countUsage(counters, at: date) }
    }

    /// Starts the usage counters over, after any counts already submitted. Saved history is unchanged.
    func resetUsage() async throws {
        guard let store else { throw JotError.message("Saved history is unavailable.") }
        try await storeExecutor.perform { try store.resetUsage() }
    }
}
