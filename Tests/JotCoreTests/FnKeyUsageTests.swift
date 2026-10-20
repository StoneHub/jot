import XCTest
@testable import JotCore

final class FnKeyUsageTests: XCTestCase {
    func testStoredValuesMapToTheirConflict() {
        XCTAssertNil(FnKeyUsage(storedValue: 0)?.conflict)
        XCTAssertEqual(FnKeyUsage(storedValue: 1)?.conflict, "changes the input source")
        XCTAssertEqual(FnKeyUsage(storedValue: 2)?.conflict, "opens Emoji & Symbols")
        XCTAssertEqual(FnKeyUsage(storedValue: 3)?.conflict, "starts macOS Dictation")
    }

    func testMissingOrUnknownValuesWarnAboutNothing() {
        XCTAssertNil(FnKeyUsage(storedValue: nil))
        XCTAssertNil(FnKeyUsage(storedValue: 9))
        XCTAssertNil(FnKeyUsage(storedValue: "2"))
    }
}
