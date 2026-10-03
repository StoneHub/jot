import ApplicationServices
import XCTest
@testable import JotCore

final class FieldInsertionReadbackTests: XCTestCase {
    func testExactUTF16ReplacementAndUnexpectedEdit() {
        let before = FieldInsertionSnapshot(value: "A😀 note", selection: NSRange(location: 1, length: 2))
        let inserted = FieldInsertionSnapshot(value: "Anew note", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(FieldInsertionReadback.compare(before, inserted, inserted: "new", requireValue: true), .verified)
        let edit = FieldInsertionSnapshot(value: "A😀 changed", selection: NSRange(location: 1, length: 2))
        XCTAssertEqual(FieldInsertionReadback.compare(before, edit, inserted: "new", requireValue: true), .changed)
    }

    func testMissingReadbackCannotVerifySelectionRewrite() {
        let before = FieldInsertionSnapshot(value: nil, selection: NSRange(location: 0, length: 0))
        let after = FieldInsertionSnapshot(value: nil, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(FieldInsertionReadback.compare(before, after, inserted: "new"), .verified)
        XCTAssertEqual(FieldInsertionReadback.compare(before, after, inserted: "new", requireValue: true), .unknown)
    }

    func testAmbiguousWriteNeverDispatchesTextAgain() {
        XCTAssertFalse(FieldInsertionReadback.unknown.allowsAccessibilityRetry(after: .success))
        XCTAssertFalse(FieldInsertionReadback.unknown.allowsAccessibilityRetry(after: .cannotComplete))
        XCTAssertFalse(FieldInsertionReadback.unchanged.allowsAccessibilityRetry(after: .cannotComplete))
        XCTAssertFalse(FieldInsertionReadback.changed.allowsAccessibilityRetry(after: .attributeUnsupported))
        XCTAssertFalse(FieldInsertionReadback.verified.allowsAccessibilityRetry(after: .success))
        XCTAssertTrue(FieldInsertionReadback.unchanged.allowsAccessibilityRetry(after: .success))
        XCTAssertTrue(FieldInsertionReadback.unknown.allowsAccessibilityRetry(after: .attributeUnsupported))
    }

    @MainActor func testAsyncPartialDispatchDoesNotFallBackToPaste() async throws {
        var pasted = false
        do {
            _ = try await ClipboardInsertion.deliver(paste: { pasted = true }, type: {
                await Task.yield()
                throw CancellationError()
            })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertFalse(pasted)
        let fallback = try await ClipboardInsertion.deliver(paste: { await Task.yield(); pasted = true }, type: {
            await Task.yield()
            throw ClipboardInsertion.Failure.directUnavailable
        })
        XCTAssertEqual(fallback, "clipboard_hid")
        XCTAssertTrue(pasted)
    }
}
