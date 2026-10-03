import Foundation

public struct SpeechTurn: Sendable {
    public var text: String
    public let start: Double
    public var end: Double
    public var speaker: String?
    /// Indexes into the words the turn was built from, so their evidence can be stored with the row.
    public var wordRange: Range<Int>
}
