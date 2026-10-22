import XCTest
@testable import JotCore

final class StatusReportTests: XCTestCase {
    /// The v1 key set clients read. Changing it is a contract change: update the CLI help, MCP descriptions and this list together.
    func testVersionOneKeysAreStable() {
        XCTAssertEqual(StatusReport.keys.count, 39)
        for key in ["mode", "models", "microphoneRunning", "ambientEnabled", "dictationEnabled", "fnEnabled", "fnRequested", "notice", "version"] {
            XCTAssertTrue(StatusReport.keys.contains(key), key)
        }
        XCTAssertTrue(StatusReport.keys.isDisjoint(with: StatusReport.optionalKeys))
        for (alias, current) in StatusReport.aliases { XCTAssertTrue(StatusReport.keys.contains(current), alias) }
    }

    func testConformanceAllowsOnlyTheOptionalExtras() {
        var report = Dictionary(uniqueKeysWithValues: StatusReport.keys.map { ($0, 0 as Any) })
        XCTAssertTrue(StatusReport.conforms(report))
        report["storage"] = [:] as [String: Any]
        XCTAssertTrue(StatusReport.conforms(report))
        report["surprise"] = 1
        XCTAssertFalse(StatusReport.conforms(report))
        report["surprise"] = nil; report["mode"] = nil
        XCTAssertFalse(StatusReport.conforms(report))
    }

    func testAudioRetentionWording() {
        XCTAssertEqual(StatusReport.audioRetention(keepForSpeakerPass: false, keepTuningCopy: true), "bounded RAM only; no recordings saved")
        XCTAssertEqual(StatusReport.audioRetention(keepForSpeakerPass: true, keepTuningCopy: false), "session audio kept until the speaker pass finishes, then deleted")
        XCTAssertTrue(StatusReport.audioRetention(keepForSpeakerPass: true, keepTuningCopy: true).hasSuffix("a copy is kept up to 30 days and 10 GB for tuning"))
    }
}
