import XCTest
@testable import PorchCore

final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porch-store-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func transcript(_ id: String, session: String = "session-a", text: String = "hello", seconds: Double = 0) -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: seconds, endSeconds: seconds + 2, text: text, speakerID: "speaker-1", mode: "ambient")
    }

    func testSpeakerLabelsAreSessionScopedAndSurviveReopening() throws {
        do {
            let store = try TranscriptStore(directory: directory)
            try store.append(transcript("a"))
            try store.append(transcript("b", session: "session-b"))
            try store.label(sessionID: "session-a", speakerID: "speaker-1", name: "Gina")
            XCTAssertEqual(try store.read(id: "a")?.speakerLabel, "Gina")
            XCTAssertNil(try store.read(id: "b")?.speakerLabel)
            XCTAssertEqual(try store.metrics().sessionCount, 2)
        }
        let reopened = try TranscriptStore(directory: directory)
        XCTAssertEqual(try reopened.read(id: "a")?.speakerLabel, "Gina")
        XCTAssertNil(try reopened.read(id: "b")?.speakerLabel)
    }

    func testLiteralSearchDoesNotTreatUserTextAsSQLOrWildcards() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(transcript("a", text: "100% done_a\\b isn't a command"))
        try store.append(transcript("b", text: "1000 doneZa/b"))
        XCTAssertEqual(try store.search("% done_").map(\.id), ["a"])
        XCTAssertEqual(try store.search("a\\b").map(\.id), ["a"])
        XCTAssertEqual(try store.search("isn't").map(\.id), ["a"])
        XCTAssertTrue(try store.search("' OR 1=1 --").isEmpty)
        XCTAssertEqual(try store.metrics().transcriptCount, 2)
    }

    func testPaginationIsBoundedAndOrdersSegmentsChronologically() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<205 { try store.append(transcript(String(index), seconds: Double(index))) }
        XCTAssertEqual(try store.recent(limit: Int.max).count, 200)
        XCTAssertEqual(try store.recent(limit: 2, offset: 2).map(\.id), ["202", "201"])
        XCTAssertEqual(try store.search("hello", limit: 2, offset: 2).map(\.id), ["202", "201"])
        XCTAssertEqual(try store.sessions().first?.lastTranscriptAt, Date(timeIntervalSince1970: 306))
        XCTAssertGreaterThan(try store.metrics().databaseBytes, 0)
    }

    func testInvalidTranscriptRejectedAndDirectoryRestricted() throws {
        let store = try TranscriptStore(directory: directory)
        var value = transcript("bad"); value.endSeconds = -1
        XCTAssertThrowsError(try store.append(value))
        value = transcript("bad"); value.mode = "unknown"
        XCTAssertThrowsError(try store.append(value))
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRecentUsesWallClockSegmentTimeAcrossOverlappingSessions() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(transcript("late-ambient", seconds: 100))
        var dictation = transcript("earlier-dictation", session: "dictation-session")
        dictation.startedAt = Date(timeIntervalSince1970: 150)
        dictation.mode = "dictation"
        try store.append(dictation)
        XCTAssertEqual(try store.recent().map(\.id), ["late-ambient", "earlier-dictation"])
    }

    func testRefusesDirectorySymlink() throws {
        let real = directory.appendingPathExtension("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: real)
        XCTAssertThrowsError(try TranscriptStore(directory: directory))
    }

    func testCaptureEventsPersistWithoutTranscriptsAndFilterSessions() throws {
        do {
            let store = try TranscriptStore(directory: directory)
            try store.appendEvent(CaptureEvent(id: "start", sessionID: "a", timestamp: Date(timeIntervalSince1970: 100), kind: "start", detail: "Ambient capture started"))
            try store.appendEvent(CaptureEvent(id: "gap", sessionID: "a", timestamp: Date(timeIntervalSince1970: 110), kind: "overflow", detail: "Capture queue dropped a segment", durationSeconds: 3.5))
            try store.appendEvent(CaptureEvent(id: "sleep", sessionID: "b", timestamp: Date(timeIntervalSince1970: 120), kind: "sleep", detail: "Capture paused for sleep"))
            XCTAssertEqual(try store.metrics().transcriptCount, 0)
        }
        let store = try TranscriptStore(directory: directory)
        XCTAssertEqual(try store.events().map(\.id), ["sleep", "gap", "start"])
        let events = try store.events(sessionID: "a")
        XCTAssertEqual(events.map(\.id), ["gap", "start"])
        XCTAssertEqual(events[0].durationSeconds, 3.5)
        XCTAssertNil(events[1].durationSeconds)
        XCTAssertEqual(try store.events(sessionID: "a", limit: 1, offset: 1).map(\.id), ["start"])
        XCTAssertTrue(try store.events(sessionID: "a' OR 1=1 --").isEmpty)
    }

    func testCaptureEventsBoundedAndInvalidDurationsRejected() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<205 {
            try store.appendEvent(CaptureEvent(id: String(index), sessionID: "a", timestamp: Date(timeIntervalSince1970: Double(index)), kind: "pause", detail: "Capture paused"))
        }
        XCTAssertEqual(try store.events(limit: Int.max).count, 200)
        XCTAssertEqual(try store.events(limit: 2, offset: 2).map(\.id), ["202", "201"])
        for duration in [-1.0, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try store.appendEvent(CaptureEvent(sessionID: "a", kind: "gap", detail: "Gap", durationSeconds: duration)))
        }
        XCTAssertThrowsError(try store.appendEvent(CaptureEvent(sessionID: "a", kind: "gap", detail: String(repeating: "x", count: 2001))))
    }
}
