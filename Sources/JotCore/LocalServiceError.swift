import Foundation
import Darwin

public enum LocalServiceError: Error, LocalizedError {
    case unavailable(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message), .invalid(let message): return message }
    }
}
