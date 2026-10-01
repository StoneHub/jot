import XCTest
import SQLite3
@testable import JotCore

final class SuggestionHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jot-suggestions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(id: UUID = UUID(), revision: Int = 0, date: Date = Date(),
                       outcome: SuggestionHistoryEntry.Outcome = .requested,
                       complete: Bool = false) -> SuggestionHistoryEntry {
        SuggestionHistoryEntry(id: id, revision: revision, startedAt: date,
                               appBundleID: "com.openai.codex", fieldRole: .textArea,
                               purpose: .agentPrompt, plan: .reply, mode: .reply,
                               beforeEndsSentence: true, draftCharacters: 7,
                               selectionCharacters: 0,
                               selected: [.init(kind: .agentMessage, count: 1, bytes: 42)],
                               excluded: [.init(reason: .otherConversation, count: 2)],
                               deadlineMilliseconds: 2_000, generationMilliseconds: 34,
                               outcome: outcome, complete: complete)
    }

    func testPersistsFinalRevisionAndMarksOnlyUnfinishedRequestsInterruptedOnReopen() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriptStore = try TranscriptStore(directory: url)
        let history = try SuggestionHistory(sharing: transcriptStore)
        let id = UUID()
        try await history.save(entry(id: id))
        try await history.save(entry(id: id, revision: 1, outcome: .ready))
        try await history.save(entry(id: id, outcome: .failed, complete: true)) // Stale update loses.
        let current = try await history.recent()
        XCTAssertEqual(current.first?.entry.outcome, .ready)
        let finished = UUID()
        try await history.save(entry(id: finished, revision: 1, outcome: .inserted, complete: true))

        let reopened = try SuggestionHistory(sharing: transcriptStore)
        let rows = try await reopened.recent()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.entry.id == id })?.interrupted, true)
        XCTAssertEqual(rows.first(where: { $0.entry.id == finished })?.interrupted, false)
        XCTAssertEqual(rows.first(where: { $0.entry.id == finished })?.entry.outcome, .inserted)
    }

    func testBoundsRowsAndAge() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriptStore = try TranscriptStore(directory: url)
        let history = try SuggestionHistory(sharing: transcriptStore)
        let now = Date()
        try await history.save(entry(date: now.addingTimeInterval(-SuggestionHistory.maximumAge - 1)), now: now)
        for index in 0..<205 {
            try await history.save(entry(date: now.addingTimeInterval(Double(index))), now: now)
        }
        let rows = try await history.recent(limit: 200)
        XCTAssertEqual(rows.count, 200)
        XCTAssertGreaterThan(rows.last!.entry.startedAt, now)
        do { _ = try await history.recent(limit: 201); XCTFail("invalid limit accepted") } catch { }
        let expired = try await history.recent(now: now.addingTimeInterval(SuggestionHistory.maximumAge + 205))
        XCTAssertTrue(expired.isEmpty, "Old requests expire even if no new request is saved")
    }

    func testPersistenceRejectsUnboundedIdentityAndCountsAndStoresNoContent() async throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriptStore = try TranscriptStore(directory: url)
        let history = try SuggestionHistory(sharing: transcriptStore)
        let privateText = "PRIVATE FIELD AND PROMPT CONTENT"
        let bad = SuggestionHistoryEntry(id: UUID(), revision: 0, startedAt: Date(),
                                         appBundleID: privateText, fieldRole: .unknown,
                                         purpose: .textEntry, plan: .draft, mode: .draft,
                                         beforeEndsSentence: false, draftCharacters: 1,
                                         selectionCharacters: 0)
        do { try await history.save(bad); XCTFail("untrusted app text persisted") } catch { }
        let oversized = SuggestionHistoryEntry(id: UUID(), revision: 0, startedAt: Date(),
                                               appBundleID: nil, fieldRole: .unknown,
                                               purpose: .textEntry, plan: .draft, mode: .draft,
                                               beforeEndsSentence: false, draftCharacters: 1,
                                               selectionCharacters: 0,
                                               selected: [.init(kind: .screenText, count: 13, bytes: 6_001)])
        do { try await history.save(oversized); XCTFail("unbounded counts persisted") } catch { }
        let source = SuggestionSource(id: "secret-id", kind: HeardSpeech.kind, role: "unknown", origin: "jot",
                            scope: .init(conversation: privateText), timestamp: "2026-09-27T00:00:00Z",
                            revision: 1, status: .current, text: privateText)
        let usage = SuggestionHistoryEntry.usage(selected: [source], excluded: [])
        XCTAssertEqual(usage.selected, [.init(kind: .heardSpeech, count: 1, bytes: privateText.utf8.count)])
        let safe = SuggestionHistoryEntry(id: UUID(), revision: 0, startedAt: Date(),
                                          appBundleID: "com.openai.codex", fieldRole: .textArea,
                                          purpose: .agentPrompt, plan: .continuation, mode: .continuation,
                                          beforeEndsSentence: true, draftCharacters: 20,
                                          selectionCharacters: 0, selected: usage.selected,
                                          agentInput: .noVisibleMatch,
                                          outcome: .noSuggestion, reason: .init(code: privateText), complete: true)
        try await history.save(safe)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(transcriptStore.databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM suggestion_interactions", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let raw = String(decoding: Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self)
        XCTAssertFalse(raw.contains(privateText))
        XCTAssertTrue(raw.contains("rejectedOutput"), "Unknown codes become a typed reason")
        XCTAssertFalse(raw.contains("conversation"))
        XCTAssertFalse(raw.contains("cwd"))
        XCTAssertFalse(raw.contains("screenText")) // This row used only agentMessage.
    }

    func testSelectedSourceUsageCountsActualUTF8BytesWithoutRetainingText() {
        let secret = "secret 🧪"
        let source = SuggestionSource(id: "one", kind: "agent-message", role: "user", origin: "codex",
                            scope: .init(conversation: "private-id"), timestamp: "2026-09-27T00:00:00Z",
                            revision: 1, status: .current, text: secret)
        let selection = SourceSelection(selected: [source], excluded: [.init(id: "other", reason: .otherConversation)])
        let usage = SuggestionHistoryEntry.usage(selection)
        XCTAssertEqual(usage.selected, [.init(kind: .agentMessage, count: 1, bytes: secret.utf8.count)])
        XCTAssertEqual(usage.excluded, [.init(reason: .otherConversation, count: 1)])
    }
}
