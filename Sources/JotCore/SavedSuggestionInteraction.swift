import Foundation
import SQLite3

/// Adds a flag when a prior run ended before recording the request's final action.
public struct SavedSuggestionInteraction: Codable, Sendable, Equatable {
    public let entry: SuggestionHistoryEntry
    public let interrupted: Bool
}
