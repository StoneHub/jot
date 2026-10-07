import Foundation

enum CLIError: Error, LocalizedError {
    case usage(String)
    var errorDescription: String? { switch self { case .usage(let text): return text } }
}
