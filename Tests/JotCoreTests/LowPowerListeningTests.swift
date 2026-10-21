import JotCore
import XCTest

final class LowPowerListeningTests: XCTestCase {
    /// Low Power Mode slows the drain and lengthens chunks, never the other way; a setting already past the preset is kept.
    func testLowPowerOnlyEasesOff() {
        XCTAssertEqual(LowPowerListening.tickInterval(0.2, lowPower: false), 0.2)
        XCTAssertEqual(LowPowerListening.tickInterval(0.2, lowPower: true), 0.5)
        XCTAssertEqual(LowPowerListening.tickInterval(60, lowPower: true), 60)
        XCTAssertEqual(LowPowerListening.chunkMaximumSeconds(3, lowPower: false), 3)
        XCTAssertEqual(LowPowerListening.chunkMaximumSeconds(3, lowPower: true), 6)
        XCTAssertEqual(LowPowerListening.chunkMaximumSeconds(10, lowPower: true), 10)
    }
}
