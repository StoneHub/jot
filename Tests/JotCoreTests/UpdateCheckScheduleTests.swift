import XCTest
@testable import JotCore

final class UpdateCheckScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstCheckIsDue() {
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: nil, now: now))
    }

    func testChecksAtMostOnceADay() {
        let day = UpdateCheckSchedule.interval
        XCTAssertFalse(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(1 - day), now: now))
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(-day), now: now))
    }

    func testClockSetBackIsDue() {
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    func testRecordedCheckDelaysTheNext() {
        let defaults = MemoryDefaults()
        XCTAssertNil(UpdateCheckSchedule.lastCheck(in: defaults))
        UpdateCheckSchedule.recordCheck(in: defaults, at: now)
        XCTAssertEqual(UpdateCheckSchedule.lastCheck(in: defaults), now)
        XCTAssertFalse(UpdateCheckSchedule.isDue(lastCheck: UpdateCheckSchedule.lastCheck(in: defaults), now: now.addingTimeInterval(3600)))
    }

    func testDailyCheckIsASettingThatDefaultsOn() {
        let settings = JotSettings(defaults: MemoryDefaults())
        XCTAssertTrue(settings.bool(JotDefaultsKey.checkForUpdates))
        settings.set(JotDefaultsKey.checkForUpdates, false)
        XCTAssertFalse(settings.bool(JotDefaultsKey.checkForUpdates))
    }
}
