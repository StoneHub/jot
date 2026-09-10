import Foundation

/// Distinguishes the short burst of configuration notifications caused by Jot
/// selecting an input from later hardware changes that require capture to stop.
public struct AudioConfigurationChangeFilter: Sendable {
    private var expectedUntil: TimeInterval?

    public init() {}

    public mutating func expectSelectionChange(at uptime: TimeInterval, duration: TimeInterval = 1) {
        expectedUntil = uptime + max(0, duration)
    }

    public mutating func cancelExpectedChange() {
        expectedUntil = nil
    }

    public mutating func shouldIgnore(at uptime: TimeInterval) -> Bool {
        guard let expectedUntil else { return false }
        if uptime <= expectedUntil { return true }
        self.expectedUntil = nil
        return false
    }
}
