import XCTest
@testable import JotCore

final class MachTimebaseTests: XCTestCase {
    func testAppleSiliconCountsTwentyFourMillionTicksASecond() {
        let appleSilicon = MachTimebase(numer: 125, denom: 3)
        XCTAssertEqual(appleSilicon.seconds(ticks: 24_000_000), 1, accuracy: 1e-9)
    }

    func testIntelTicksAreNanoseconds() {
        let intel = MachTimebase(numer: 1, denom: 1)
        XCTAssertEqual(intel.seconds(ticks: 1_500_000_000), 1.5, accuracy: 1e-9)
    }
}
