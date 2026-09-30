import Foundation

public enum StoreError: Error, LocalizedError {
    case database(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .database(let value), .invalid(let value): return value }
    }
}
