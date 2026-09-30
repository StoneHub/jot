import XCTest
@testable import JotCore

final class NoiseFillersTests: XCTestCase {
    func testAcknowledgementsAndHesitationsAloneAreFillers() {
        for text in ["Yeah.", "Okay.", "Mm.", "Mm-hmm.", "Uh-huh", "mhm", "Yeah. Okay.", "Um, yeah.", "OK"] {
            XCTAssertTrue(NoiseFillers.isFillerOnly(text), text)
        }
    }

    func testAnyOtherWordKeepsTheBlock() {
        for text in ["Yeah, I agree.", "Okay so", "No.", "Yes.", "Right.", "Mm, that works", "Yeah, 20.", "Okay 5", "", "…"] {
            XCTAssertFalse(NoiseFillers.isFillerOnly(text), text)
        }
    }
}
