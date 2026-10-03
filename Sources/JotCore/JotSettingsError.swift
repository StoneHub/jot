import Foundation

public enum JotSettingsError: Error, LocalizedError, Equatable {
    case unknown(String)
    case invalid(String, String)
    public var errorDescription: String? {
        switch self {
        case .unknown(let key): return "Unknown setting: \(key). Run jot settings to list them."
        case .invalid(let key, let expected): return "\(key) must be \(expected)."
        }
    }
}
