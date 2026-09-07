import XCTest
@testable import DevFeedback

#if DEBUG
final class FeedbackHistoryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("history.json") }
    private func record(note: String = "Increase spacing") -> FeedbackRecord {
        FeedbackRecord(id: UUID(), createdAt: Date(), appID: "test", screen: "status",
                       target: FeedbackTarget(id: "status.save", label: "Save", file: "App/Status.swift", line: 42),
                       bounds: FeedbackBounds(x: 1, y: 2, width: 30, height: 40), appVersion: "1", build: "2", appearance: "dark",
                       note: note, acceptance: "Readable at the minimum window size")
    }
    func testRoundTripEditingPreservesCaptureAndSelectedExport() throws {
        let history = try FeedbackHistory(url: url)
        let first = record()
        let other = record(note: "Unselected private note")
        try history.save(first)
        try history.save(other)
        var edit = first
        edit.note = "Use larger spacing"
        try history.save(edit)
        let loaded = try FeedbackHistory(url: url)
        XCTAssertEqual(loaded.records.count, 2)
        XCTAssertEqual(loaded.records.last?.target, first.target)
        XCTAssertEqual(loaded.records.last?.createdAt, first.createdAt)
        XCTAssertEqual(loaded.records.last?.note, edit.note)
        let selected = loaded.selected([first.id])
        let exported = try JSONDecoder().decode(FeedbackBundle.self, from: FeedbackHistory.json(selected))
        XCTAssertEqual(exported.records.map(\.id), [first.id])
        XCTAssertFalse(FeedbackHistory.markdown(selected).contains(other.note))
        XCTAssertTrue(FeedbackHistory.markdown(selected).contains("App/Status.swift:42"))
        try loaded.delete(ids: [other.id])
        XCTAssertEqual(try FeedbackHistory(url: url).records.map(\.id), [first.id])
    }
    func testIndependentWindowsMergeAndFinderDeletionIsRespected() throws {
        let firstWindow = try FeedbackHistory(url: url)
        let secondWindow = try FeedbackHistory(url: url)
        let first = record()
        let second = record(note: "Second window")
        try firstWindow.save(first)
        try secondWindow.save(second)
        XCTAssertEqual(try FeedbackHistory(url: url).records.count, 2)
        try firstWindow.delete(ids: [first.id])
        XCTAssertEqual(try FeedbackHistory(url: url).records.map(\.id), [second.id])
        try FileManager.default.removeItem(at: url)
        let fresh = record(note: "After emptying history in Finder")
        try secondWindow.save(fresh)
        XCTAssertEqual(try FeedbackHistory(url: url).records.map(\.id), [fresh.id])
    }
    func testWriteFailureDoesNotPublishUnsavedRecord() throws {
        let history = try FeedbackHistory(url: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try history.save(record()))
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCorruptOrFutureHistoryIsPreserved() throws {
        let invalid = Data("not json".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try FeedbackHistory(url: url))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        let future = Data("{\"schemaVersion\":2,\"source\":\"swiftui-dev-feedback\",\"records\":[]}".utf8)
        try future.write(to: url)
        XCTAssertThrowsError(try FeedbackHistory(url: url))
        XCTAssertEqual(try Data(contentsOf: url), future)
    }
    func testRejectsEmptyAndOversizeNotes() throws {
        let history = try FeedbackHistory(url: url)
        XCTAssertThrowsError(try history.save(record(note: " \n ")))
        XCTAssertThrowsError(try history.save(record(note: String(repeating: "a", count: 16_001))))
        XCTAssertTrue(history.records.isEmpty)
    }
}
#endif
