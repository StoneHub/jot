import CoreGraphics
import Foundation

/// One run of visible text read through Accessibility, in Accessibility screen coordinates (origin top-left, y down).
public struct ScreenText: Equatable, Sendable {
    public init(_ text: String, frame: CGRect) { self.text = text; self.frame = frame }
    public let text: String
    public let frame: CGRect
}
