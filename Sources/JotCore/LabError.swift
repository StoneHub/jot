import Foundation

public enum LabError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let value): return value }
    }
}
