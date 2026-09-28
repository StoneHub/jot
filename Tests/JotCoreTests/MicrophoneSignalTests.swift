import XCTest
@testable import JotCore

final class MicrophoneSignalTests: XCTestCase {
    func testDigitalSilenceAndQuietRoomDiffer() {
        var silent = MicrophoneSignal(), room = MicrophoneSignal()
        for _ in 0..<50 {
            silent.observe(samples: 3200, rms: 0)
            room.observe(samples: 3200, rms: 0.0003)
        }
        XCTAssertTrue(silent.isSilent)
        XCTAssertFalse(room.isSilent)
        XCTAssertTrue(room.heardSound)
        silent.observe(samples: 3200, rms: 0.01)
        XCTAssertFalse(silent.isSilent)
    }

    func testSearchTriesOnceAndRestoresSystemDefault() {
        var silence = MicrophoneSignal(), search = MicrophoneInputSearch()
        silence.observe(samples: 160_000, rms: 0)
        XCTAssertEqual(search.next(current: "", resolved: "built-in", candidates: ["built-in", "hub", "headset"], signal: silence), "hub")
        var checking = MicrophoneSignal()
        checking.observe(samples: 16_000, rms: 0)
        XCTAssertNil(search.next(current: "hub", resolved: "hub", candidates: ["hub", "headset"], signal: checking))
        checking.observe(samples: 32_000, rms: 0)
        XCTAssertEqual(search.next(current: "hub", resolved: "hub", candidates: ["hub", "headset"], signal: checking), "headset")
        XCTAssertEqual(search.next(current: "headset", resolved: "headset", candidates: ["hub", "headset"], signal: checking), "")
        XCTAssertFalse(search.isSearching)
        XCTAssertNil(search.next(current: "", resolved: "built-in", candidates: ["hub", "headset"], signal: silence))
    }

    func testSearchKeepsAnInputWithSignal() {
        var signal = MicrophoneSignal(), search = MicrophoneInputSearch()
        signal.observe(samples: 160_000, rms: 0)
        XCTAssertEqual(search.next(current: "built-in", resolved: "built-in", candidates: ["hub"], signal: signal), "hub")
        signal = MicrophoneSignal()
        signal.observe(samples: 48_000, rms: 0.01)
        XCTAssertNil(search.next(current: "hub", resolved: "hub", candidates: ["built-in"], signal: signal))
        XCTAssertFalse(search.isSearching)
    }
}
