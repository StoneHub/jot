import JotCore
import XCTest

final class AudioLevelTests: XCTestCase {
    /// A quiet block stays below the gate, and one loud window anywhere in it, including a short tail, lifts the block above it.
    func testLoudestWindowFindsShortSoundInQuietBlock() {
        XCTAssertEqual(AudioLevel.loudestWindowRMS([]), 0)
        let quiet = [Float](repeating: 0.0005, count: 16_000 * 3)
        XCTAssertEqual(AudioLevel.loudestWindowRMS(quiet), 0.0005, accuracy: 0.00001)
        var word = quiet
        for index in 20_000..<21_600 { word[index] = index.isMultiple(of: 2) ? 0.05 : -0.05 }
        XCTAssertEqual(AudioLevel.loudestWindowRMS(word), 0.05, accuracy: 0.0001)
        let tail = quiet + [Float](repeating: 0.01, count: 400)
        XCTAssertEqual(AudioLevel.loudestWindowRMS(tail), 0.01, accuracy: 0.0001)
    }
}
