import XCTest
@testable import JotCore

final class BatteryUsageTests: XCTestCase {
    func testDischargeAndChargeCycles() {
        var usage = BatteryUsage()
        usage.observe(level: 80, onBattery: true)
        usage.observe(level: 77, onBattery: true)
        XCTAssertEqual(usage.usedPercentagePoints, 3)
        usage.observe(level: 78, onBattery: false)
        usage.observe(level: 95, onBattery: false)
        XCTAssertEqual(usage.usedPercentagePoints, 3)
        usage.observe(level: 94, onBattery: true)
        usage.observe(level: 92, onBattery: true)
        XCTAssertEqual(usage.usedPercentagePoints, 5)
    }
    func testGaugeBounceDoesNotDoubleCount() {
        var usage = BatteryUsage()
        for level in [80.0, 79, 80, 79] { usage.observe(level: level, onBattery: true) }
        XCTAssertEqual(usage.usedPercentagePoints, 1)
    }
    func testUnavailableReadingBreaksInterval() {
        var usage = BatteryUsage()
        usage.observe(level: 80, onBattery: true)
        usage.observe(level: 78, onBattery: true)
        usage.observe(level: nil, onBattery: nil)
        XCTAssertNil(usage.levelPercent)
        usage.observe(level: 40, onBattery: true)
        XCTAssertEqual(usage.usedPercentagePoints, 2)
        usage.observe(level: .nan, onBattery: true)
        XCTAssertNil(usage.levelPercent)
    }
}
