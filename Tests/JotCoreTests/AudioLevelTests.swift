import JotCore
import XCTest

final class AudioLevelTests: XCTestCase {
    /// A quiet block stays below the gate, and one tenth of a second of sound anywhere in it, including across what used to
    /// be a window boundary or at the block's end, reads at its own level.
    func testLoudestWindowFindsShortSoundInQuietBlock() {
        XCTAssertEqual(AudioLevel.loudestWindowRMS([]), 0)
        let quiet = [Float](repeating: 0.0005, count: 16_000 * 3)
        XCTAssertEqual(AudioLevel.loudestWindowRMS(quiet), 0.0005, accuracy: 0.00001)
        for start in [20_000, 20_400, 20_800] {
            var word = quiet
            for index in start..<(start + 1_600) { word[index] = index.isMultiple(of: 2) ? 0.05 : -0.05 }
            XCTAssertEqual(AudioLevel.loudestWindowRMS(word), 0.05, accuracy: 0.0001, "a word starting at sample \(start)")
        }
        let tail = quiet + [Float](repeating: 0.01, count: 800)
        XCTAssertEqual(AudioLevel.loudestWindowRMS(tail), 0.01, accuracy: 0.0001)
        let head = [Float](repeating: 0.01, count: 800) + quiet
        XCTAssertEqual(AudioLevel.loudestWindowRMS(head), 0.01, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.loudestWindowRMS([0.02, -0.02, 0.02]), 0.02, accuracy: 0.0001)
    }
}
