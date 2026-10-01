import Foundation

public enum ModelCallResult: Equatable {
    case output(String)
    case unavailable(String)
    case failed
    case timedOut
    case cancelled
    /// An earlier request has not returned, so nothing was started.
    case blocked
}
