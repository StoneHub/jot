import Foundation

public struct AttributedWord: Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let probabilities: [Float]
    public init(text: String, start: Double, end: Double, probabilities: [Float]) {
        self.text = text; self.start = start; self.end = end; self.probabilities = probabilities
    }
}
