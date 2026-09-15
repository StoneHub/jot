import AppKit
import XCTest
@testable import JotCore

final class DictationDeliveryTests: XCTestCase {
    private final class MissingClipboardData: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
    }

    @MainActor func testUnreadableClipboardRepresentationCannotBlockDirectInsertion() throws {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let provider = MissingClipboardData()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(clipboard.writeObjects([item]))
        XCTAssertThrowsError(try ClipboardInsertion.snapshot(clipboard))
        let before = clipboard.changeCount
        var inserted = false
        let route = try ClipboardInsertion.deliver(paste: { _ = try ClipboardInsertion.snapshot(clipboard) }, type: { inserted = true })
        XCTAssertTrue(inserted)
        XCTAssertEqual(route, "unicode_hid")
        XCTAssertEqual(clipboard.changeCount, before)
    }

    @MainActor func testDirectInsertionDoesNotReadOrChangeClipboard() throws {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("existing clipboard", forType: .string)
        let before = clipboard.changeCount
        var delivered = ""
        let text = "Hello 👩🏽‍💻 — café.\nNext paragraph."
        let route = try ClipboardInsertion.deliver(paste: {
            XCTFail("Direct insertion must not use the clipboard")
            throw ClipboardInsertion.Failure.unavailable
        }, type: {
            for chunk in UnicodeTyping.chunks(text) { delivered += String(decoding: chunk, as: UTF16.self) }
        })
        XCTAssertEqual(route, "unicode_hid")
        XCTAssertEqual(delivered, text)
        XCTAssertEqual(clipboard.changeCount, before)
        XCTAssertEqual(clipboard.string(forType: .string), "existing clipboard")
    }

    @MainActor func testClipboardUsedOnlyWhenDirectInsertionCannotStart() throws {
        var pasted = false
        let route = try ClipboardInsertion.deliver(paste: { pasted = true }, type: { throw ClipboardInsertion.Failure.directUnavailable })
        XCTAssertTrue(pasted)
        XCTAssertEqual(route, "clipboard_hid")
        enum FocusError: Error { case moved }
        XCTAssertThrowsError(try ClipboardInsertion.deliver(paste: { XCTFail("Never retry after focus changes or partial delivery") }, type: { throw FocusError.moved }))
    }

    func testUnicodeChunksNeverSplitSurrogatePairs() {
        let text = String(repeating: "a", count: 19) + "😀" + String(repeating: "👩🏽‍💻 café\n", count: 20)
        let chunks = UnicodeTyping.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        XCTAssertTrue(UnicodeTyping.chunks("").isEmpty)
    }

    func testFailedDictationRetainsSeparateStageTimings() throws {
        var diagnostics = PerformanceDiagnostics()
        diagnostics.record(.init(elapsedSeconds: 10, mode: .dictation, outcome: .failed,
            audioSeconds: 7, queueWaitSeconds: 0.2, inferenceSeconds: 0.1, completionSeconds: 0.4,
            cleanupSeconds: 0, deliverySeconds: 0.08))
        let report = try JSONDecoder().decode(PerformanceReport.self, from: diagnostics.export())
        XCTAssertEqual(report.jobs.last?.cleanupSeconds, 0)
        XCTAssertEqual(report.jobs.last?.deliverySeconds, 0.08)
        XCTAssertEqual(report.jobs.last?.queueWaitSeconds, 0.2)
    }
}
