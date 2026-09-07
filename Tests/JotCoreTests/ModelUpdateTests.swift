import XCTest
@testable import JotCore
final class ModelUpdateTests: XCTestCase {
    func testInitialCheckDoesNotClaimInstalledModelsAreCurrent() throws {
        let model = ModelUpdate.defaults[0]
        let data = Data("{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lastModified\":\"2026-09-06T00:00:00Z\"}".utf8)
        let checked = try model.applying(data, at: Date())
        XCTAssertFalse(checked.changedSinceLastCheck)
        XCTAssertTrue(checked.summary.contains("installed cache has no recorded revision"))
        XCTAssertTrue(checked.summary.contains("2026-09-06"))
    }
    func testDetectsUpstreamChangeAndRejectsInvalidRevision() throws {
        let a = Data("{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}".utf8)
        let b = Data("{\"sha\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}".utf8)
        let first = try ModelUpdate.defaults[1].applying(a, at: Date())
        XCTAssertFalse(try first.applying(a, at: Date()).changedSinceLastCheck)
        XCTAssertTrue(try first.applying(b, at: Date()).changedSinceLastCheck)
        XCTAssertThrowsError(try first.applying(Data("{\"sha\":\"invalid\"}".utf8), at: Date()))
    }
}
