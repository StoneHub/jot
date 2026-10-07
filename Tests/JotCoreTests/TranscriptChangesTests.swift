import XCTest
import SQLite3
@testable import JotCore

/// `transcripts.since`: a follower polling the change feed sees every row once, and a cleanup or relabel as the same row id again.
final class TranscriptChangesTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-changes-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, session: String, seconds: Double, text: String? = nil, speaker: String? = "speaker-1") -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: Date(timeIntervalSince1970: 100), startSeconds: seconds, endSeconds: seconds + 1,
                   text: text ?? "raw \(id)", speakerID: speaker, mode: "ambient")
    }

    /// A follower that polls like an agent would every two seconds: it reads pages until caught up and keeps each text it was handed, by row id.
    private final class Follower {
        let store: TranscriptStore
        let sessionID: String?
        var cursor: Int64 = 0
        var deliveries: [String: [String]] = [:]
        var order: [String] = []
        init(_ store: TranscriptStore, sessionID: String? = nil) { self.store = store; self.sessionID = sessionID }

        @discardableResult func poll(limit: Int = 2, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
            var received = 0
            while true {
                let page = try store.changes(since: cursor, sessionID: sessionID, limit: limit)
                XCTAssertFalse(page.reset, file: file, line: line)
                XCTAssertLessThanOrEqual(page.rows.count, limit, file: file, line: line)
                XCTAssertEqual(Set(page.rows.map(\.transcript.id)).count, page.rows.count, "A page lists a row at most once", file: file, line: line)
                XCTAssertEqual(page.rows.map(\.sequence), page.rows.map(\.sequence).sorted(), file: file, line: line)
                XCTAssertGreaterThanOrEqual(page.cursor, cursor, file: file, line: line)
                for change in page.rows {
                    if deliveries[change.transcript.id] == nil { order.append(change.transcript.id) }
                    deliveries[change.transcript.id, default: []].append(change.transcript.text)
                }
                received += page.rows.count
                cursor = page.cursor
                XCTAssertEqual(page.pollAfterSeconds, page.hasMore ? 0 : TranscriptChanges.caughtUpPollSeconds, file: file, line: line)
                if !page.hasMore { return received }
            }
        }
    }

    func testPollingDeliversEveryRowOnceAcrossCleanupRewritesAndSessionRotation() throws {
        let store = try TranscriptStore(directory: directory)
        let follower = Follower(store)
        XCTAssertEqual(try follower.poll(), 0, "An empty store has nothing to deliver")
        XCTAssertEqual(follower.cursor, 0)

        let a1 = row("a1", session: "A", seconds: 0), a2 = row("a2", session: "A", seconds: 1), a3 = row("a3", session: "A", seconds: 2)
        for item in [a1, a2, a3] { try store.append(item) }
        XCTAssertEqual(try follower.poll(), 3)

        // Cleanup lands after the follower saw the recognized text: the same id comes back with cleaned text.
        try store.setReadablePhrase(["clean a1"], for: [a1])
        let a4 = row("a4", session: "A", seconds: 3)
        try store.append(a4)
        XCTAssertEqual(try follower.poll(), 2)

        // Cleanup that lands before the next poll folds into the row's first delivery.
        let a5 = row("a5", session: "A", seconds: 4)
        try store.append(a5)
        try store.setReadablePhrase(["clean a5"], for: [a5])
        XCTAssertEqual(try follower.poll(), 1)

        // Quiet ends session A and capture continues in session B; the cursor does not care.
        let b1 = row("b1", session: "B", seconds: 900), b2 = row("b2", session: "B", seconds: 901)
        try store.append(b1)
        XCTAssertEqual(try follower.poll(), 1)
        try store.append(b2)
        XCTAssertTrue(try store.setReadablePhrase(["clean b1", "clean b2"], for: [b1, b2]))
        // A late cleanup of the old session still arrives after rotation.
        try store.setReadablePhrase(["clean a3"], for: [a3])
        XCTAssertEqual(try follower.poll(), 3)

        let caughtUp = follower.cursor
        XCTAssertEqual(try follower.poll(), 0, "A caught-up poll returns nothing")
        XCTAssertEqual(follower.cursor, caughtUp)

        XCTAssertEqual(follower.order, ["a1", "a2", "a3", "a4", "a5", "b1", "b2"], "Every row is first delivered once, in the order it arrived")
        XCTAssertEqual(follower.deliveries, [
            "a1": ["raw a1", "clean a1"],
            "a2": ["raw a2"],
            "a3": ["raw a3", "clean a3"],
            "a4": ["raw a4"],
            "a5": ["clean a5"],
            "b1": ["raw b1", "clean b1"],
            "b2": ["clean b2"]
        ])

        // A follower that joins late with a session filter sees only that session, once, with current text.
        let late = Follower(store, sessionID: "B")
        XCTAssertEqual(try late.poll(limit: 1), 2)
        XCTAssertEqual(late.deliveries, ["b1": ["clean b1"], "b2": ["clean b2"]])
        XCTAssertEqual(late.cursor, caughtUp, "Rows of other sessions still advance a filtered cursor")
    }

    func testSpeakerRelabelIsAnUpdateAndAnUnchangedSpeakerIsNotRedelivered() throws {
        let store = try TranscriptStore(directory: directory)
        let a1 = row("a1", session: "A", seconds: 0)
        try store.append(a1)
        try store.appendWords([StoredWord(transcriptID: "a1", position: 0, word: "raw", startSeconds: 0, endSeconds: 0.4, probabilities: []),
                               StoredWord(transcriptID: "a1", position: 1, word: "a1", startSeconds: 0.5, endSeconds: 1, probabilities: [])])
        try store.label(sessionID: "A", speakerID: "speaker-2", name: "Gina")
        let follower = Follower(store)
        XCTAssertEqual(try follower.poll(), 1)

        XCTAssertTrue(try store.relabelSession("A") { $0.map { _ in "speaker-1" } })
        XCTAssertEqual(try follower.poll(), 0, "Writing the same speaker is not a change")

        XCTAssertTrue(try store.relabelSession("A") { $0.map { _ in "speaker-2" } })
        let page = try store.changes(since: follower.cursor)
        XCTAssertEqual(page.rows.map(\.transcript.id), ["a1"])
        XCTAssertEqual(page.rows.first?.transcript.speakerID, "speaker-2")
        XCTAssertEqual(page.rows.first?.transcript.speakerLabel, "Gina")
    }

    func testCursorAheadOfTheStoreRestartsFromTheBeginning() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0))
        let page = try store.changes(since: 500)
        XCTAssertTrue(page.reset)
        XCTAssertEqual(page.rows.map(\.transcript.id), ["a1"])
        XCTAssertEqual(page.cursor, 1)
        XCTAssertFalse(try store.changes(since: page.cursor).reset)
        XCTAssertThrowsError(try store.changes(since: -1))
    }

    func testDeletedRowsLeaveLiveRowsAndNumbersAreNeverReused() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0))
        try store.append(row("b1", session: "B", seconds: 10))
        try store.deleteSession(id: "A")
        XCTAssertEqual(try store.changes(since: 0).rows.map(\.transcript.id), ["b1"])
        try store.append(row("c1", session: "C", seconds: 20))
        let page = try store.changes(since: 2)
        XCTAssertEqual(page.deleted.map(\.sequence), [3])
        XCTAssertEqual(page.rows.map(\.sequence), [4])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM transcript_changes"), 2, "A deleted row keeps no entry")
    }

    func testRowsSavedBeforeTheFeedJoinItInSpokenOrderOnce() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE transcripts (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL, start_seconds REAL NOT NULL, end_seconds REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, mode TEXT NOT NULL CHECK(mode IN ('ambient','dictation')));
            CREATE TABLE transcript_readable (transcript_id TEXT PRIMARY KEY REFERENCES transcripts(id) ON DELETE CASCADE, text TEXT NOT NULL);
            INSERT INTO transcripts VALUES('later','s',100,5,6,'second','speaker-1','ambient');
            INSERT INTO transcripts VALUES('earlier','s',100,1,2,'first','speaker-1','ambient');
            INSERT INTO transcript_readable VALUES('earlier','First.');
            PRAGMA user_version=7;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = try TranscriptStore(directory: directory)
            let page = try store.changes(since: 0)
            XCTAssertEqual(page.rows.map(\.transcript.id), ["earlier", "later"])
            XCTAssertEqual(page.rows.map(\.transcript.text), ["First.", "second"])
            XCTAssertEqual(page.cursor, 2)
        }
        XCTAssertEqual(try count("PRAGMA user_version"), 8)
        let reopened = try TranscriptStore(directory: directory)
        XCTAssertEqual(try reopened.changes(since: 0).rows.map(\.sequence), [1, 2], "Reopening does not enqueue rows again")
    }

    func testChangeEncodesFlatWithTheTranscriptKeys() throws {
        let change = TranscriptChange(row("a1", session: "A", seconds: 0), sequence: 7)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(TranscriptChanges(rows: [change], cursor: 7, hasMore: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["cursor"] as? Int, 7)
        XCTAssertEqual(object["hasMore"] as? Bool, false)
        XCTAssertEqual(object["pollAfterSeconds"] as? Double, 2)
        let first = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["id"] as? String, "a1")
        XCTAssertEqual(first["text"] as? String, "raw a1")
        XCTAssertEqual(first["sequence"] as? Int, 7)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TranscriptChanges.self, from: data).rows, [change])
    }

    private func object(_ page: TranscriptChanges) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }

    func testDeleteSessionReportsAnIDOnlyTombstoneAfterTheFollowersCursor() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0, text: "private synthetic text"))
        let cursor = try store.changes(since: 0).cursor
        try store.deleteSession(id: "A")
        let page = try store.changes(since: cursor, sessionID: "A", limit: 1)
        let deleted = try XCTUnwrap(try object(page)["deleted"] as? [[String: Any]])
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?["id"] as? String, "a1")
        XCTAssertEqual(deleted.first?["sessionID"] as? String, "A")
        XCTAssertNil(deleted.first?["text"])
        XCTAssertGreaterThan(page.cursor, cursor)
        XCTAssertTrue(page.rows.isEmpty)
    }

    func testSpeakerNamingRenamingAndRemovingNamesRedeliversOnlyAffectedRows() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("a1", session: "A", seconds: 0))
        try store.append(row("a2", session: "A", seconds: 1, speaker: "speaker-2"))
        try store.append(row("b1", session: "B", seconds: 0))
        var cursor = try store.changes(since: 0).cursor
        for name in ["Gina", "Ada"] {
            try store.label(sessionID: "A", speakerID: "speaker-1", name: name)
            let page = try store.changes(since: cursor)
            XCTAssertEqual(page.rows.map(\.transcript.id), ["a1"])
            XCTAssertEqual(page.rows.first?.transcript.speakerLabel, name)
            cursor = page.cursor
            try store.label(sessionID: "A", speakerID: "speaker-1", name: name)
            XCTAssertTrue(try store.changes(since: cursor).rows.isEmpty)
        }
        try store.replaceLabels(sessionID: "A", ["speaker-1": "Ada"])
        XCTAssertTrue(try store.changes(since: cursor).rows.isEmpty, "Replacing unchanged names must not redeliver rows")
        try store.replaceLabels(sessionID: "A", [:])
        let removed = try store.changes(since: cursor)
        XCTAssertEqual(removed.rows.map(\.transcript.id), ["a1"])
        XCTAssertNil(removed.rows.first?.transcript.speakerLabel)
    }

    func testSplitRemovesTheParentFromAPagedFollowersCopy() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("parent", session: "A", seconds: 0, text: "one two"))
        try store.appendWords([
            StoredWord(transcriptID: "parent", position: 0, word: "one", startSeconds: 0, endSeconds: 0.4, probabilities: []),
            StoredWord(transcriptID: "parent", position: 1, word: "two", startSeconds: 0.5, endSeconds: 1, probabilities: [])
        ])
        var copy = ["parent": "one two"]
        var cursor = try store.changes(since: 0).cursor
        XCTAssertTrue(try store.relabelSession("A") { _ in ["speaker-1", "speaker-2"] })
        repeat {
            let page = try store.changes(since: cursor, sessionID: "A", limit: 1)
            for deletion in try object(page)["deleted"] as? [[String: Any]] ?? [] {
                if let id = deletion["id"] as? String { copy.removeValue(forKey: id) }
            }
            for change in page.rows { copy[change.transcript.id] = change.transcript.text }
            cursor = page.cursor
            if !page.hasMore { break }
        } while true
        let source = try store.session(id: "A")
        XCTAssertEqual(copy, Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.text) }))
        XCTAssertNil(copy["parent"], "A split must remove the old text before delivering its pieces")
    }

    func testOmittingTheCursorSubscribesAtHeadWhileExplicitZeroReplaysHistory() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<6 { try store.append(row("a\(index)", session: "A", seconds: Double(index))) }
        let subscribed = try store.changes(limit: 1)
        XCTAssertTrue(subscribed.rows.isEmpty)
        XCTAssertFalse(subscribed.hasMore)
        XCTAssertEqual(subscribed.cursor, 6)
        XCTAssertEqual(try store.changes(since: 0, limit: 1).rows.map(\.transcript.id), ["a0"])
    }

    func testGenerationPersistsAcrossReopenAndChangesWithARecreatedStore() throws {
        let first = try TranscriptStore(directory: directory)
        let generation = try XCTUnwrap(try object(first.changes(since: 0))["generation"] as? String)
        let reopened = try TranscriptStore(directory: directory)
        XCTAssertEqual(try object(reopened.changes(since: 0))["generation"] as? String, generation)
        let other = try TranscriptStore(directory: directory.appendingPathComponent("new-store"))
        XCTAssertNotEqual(try object(other.changes(since: 0))["generation"] as? String, generation)
    }

    func testGenerationResetsEvenWhenTheNewHeadHasPassedTheOldCursor() throws {
        let old = try TranscriptStore(directory: directory)
        try old.append(row("old", session: "A", seconds: 0))
        let previous = try old.changes(since: 0)
        let replacement = try TranscriptStore(directory: directory.appendingPathComponent("replacement"))
        for index in 0..<3 { try replacement.append(row("new\(index)", session: "A", seconds: Double(index))) }
        let reset = try replacement.changes(since: previous.cursor, generation: previous.generation, limit: 1)
        XCTAssertTrue(reset.reset)
        XCTAssertTrue(reset.hasMore)
        XCTAssertEqual(reset.rows.map(\.transcript.id), ["new0"])
        let next = try replacement.changes(since: reset.cursor, generation: reset.generation)
        XCTAssertFalse(next.reset)
        XCTAssertEqual(next.rows.map(\.transcript.id), ["new1", "new2"])
        XCTAssertFalse(try replacement.changes(since: previous.cursor).reset, "Legacy numeric-only polling keeps its behavior")
        XCTAssertThrowsError(try replacement.changes(since: 0, generation: ""))

        let empty = try TranscriptStore(directory: directory.appendingPathComponent("empty"))
        let emptyReset = try empty.changes(since: 0, generation: previous.generation)
        XCTAssertTrue(emptyReset.reset)
        XCTAssertEqual(emptyReset.cursor, 0)
        XCTAssertTrue(emptyReset.rows.isEmpty)
    }

    func testClearAndIndividualDeletionSharePaginationWithLiveRowsAndSurviveReopen() throws {
        var store = try TranscriptStore(directory: directory)
        try store.append(row("ambient", session: "A", seconds: 0))
        var dictation = row("dictation", session: "D", seconds: 0)
        dictation.mode = "dictation"
        try store.append(dictation)
        var cursor = try store.changes(since: 0).cursor
        try store.clearHistory()
        try store.append(row("later", session: "B", seconds: 0))
        try store.deleteTranscripts(ids: ["ambient", "ambient", "missing"])
        let generation = store.generation
        store = try TranscriptStore(directory: directory)
        XCTAssertEqual(store.generation, generation)
        var deleted: [String] = []
        var live: [String] = []
        repeat {
            let page = try store.changes(since: cursor, generation: generation, limit: 1)
            XCTAssertEqual(page.rows.count + page.deleted.count, 1)
            XCTAssertGreaterThan(page.cursor, cursor)
            deleted += page.deleted.map(\.id)
            live += page.rows.map(\.transcript.id)
            cursor = page.cursor
            if !page.hasMore { break }
        } while true
        XCTAssertEqual(deleted, ["dictation", "ambient"])
        XCTAssertEqual(live, ["later"])
        let unrelated = try store.changes(since: 0, sessionID: "unrelated", limit: 1)
        XCTAssertEqual(unrelated.cursor, cursor)
        XCTAssertTrue(unrelated.rows.isEmpty && unrelated.deleted.isEmpty)
        XCTAssertFalse(unrelated.hasMore)
        try store.deleteTranscripts(ids: ["missing"])
        XCTAssertEqual(try store.changes(since: cursor).cursor, cursor)
    }

    func testReinsertingAnIDCoalescesItsTombstoneIntoTheLatestLiveChange() throws {
        let store = try TranscriptStore(directory: directory)
        let original = row("a1", session: "A", seconds: 0)
        try store.append(original)
        let cursor = try store.changes(since: 0).cursor
        try store.deleteTranscripts(ids: [original.id])
        try store.append(original)
        let page = try store.changes(since: cursor, limit: 1)
        XCTAssertTrue(page.deleted.isEmpty)
        XCTAssertEqual(page.rows.map(\.transcript.id), [original.id])
        XCTAssertFalse(page.hasMore)
    }

    func testOldWirePagesStillDecodeAndNewFieldsRoundTrip() throws {
        let legacy = Data(#"{"rows":[],"cursor":4,"hasMore":false,"reset":false,"pollAfterSeconds":2}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptChanges.self, from: legacy)
        XCTAssertEqual(decoded.cursor, 4)
        XCTAssertTrue(decoded.deleted.isEmpty)
        XCTAssertNil(decoded.generation)
        let page = TranscriptChanges(rows: [], cursor: 5, hasMore: false,
            deleted: [.init(id: "a1", sessionID: "A", sequence: 5)], generation: "generation")
        XCTAssertEqual(try JSONDecoder().decode(TranscriptChanges.self, from: JSONEncoder().encode(page)), page)
    }

    func testCrossSessionReinsertionRetainsTheOldSessionsDeletion() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(row("same-id", session: "A", seconds: 0))
        let cursor = try store.changes(since: 0, sessionID: "A").cursor
        try store.deleteTranscripts(ids: ["same-id"])
        try store.append(row("same-id", session: "B", seconds: 0))
        let oldSession = try store.changes(since: cursor, sessionID: "A", limit: 1)
        XCTAssertEqual(oldSession.deleted, [.init(id: "same-id", sessionID: "A", sequence: 2)])
        XCTAssertTrue(oldSession.rows.isEmpty)
        XCTAssertEqual(oldSession.cursor, 3)
        let global = try store.changes(since: cursor, limit: 1)
        XCTAssertEqual(global.rows.map(\.transcript.sessionID), ["B"])
        XCTAssertTrue(global.deleted.isEmpty, "The global follower replaces the id with its latest live row")
        XCTAssertFalse(global.hasMore)
    }

    func testRepeatedCrossSessionReuseConvergesWithMixedPagesAndNoDuplicateIDs() throws {
        let store = try TranscriptStore(directory: directory)
        var cursors: [String: Int64] = [:]
        var copies: [String: [String: String]] = [:]
        func poll() throws {
            for key in ["all", "A", "B", "C"] {
                let sessionID = key == "all" ? nil : key
                var seen = Set<String>()
                var copy = copies[key] ?? [:]
                repeat {
                    let cursor = cursors[key] ?? 0
                    let page = try store.changes(since: cursor, generation: store.generation, sessionID: sessionID, limit: 1)
                    XCTAssertFalse(page.reset)
                    XCTAssertLessThanOrEqual(page.rows.count + page.deleted.count, 1)
                    XCTAssertGreaterThanOrEqual(page.cursor, cursor)
                    for deletion in page.deleted {
                        XCTAssertTrue(seen.insert(deletion.id).inserted, "One latest change per id, across all pages")
                        copy.removeValue(forKey: deletion.id)
                    }
                    for change in page.rows {
                        XCTAssertTrue(seen.insert(change.transcript.id).inserted)
                        copy[change.transcript.id] = change.transcript.text
                    }
                    cursors[key] = page.cursor
                    if !page.hasMore { break }
                } while true
                copies[key] = copy
                let source = try sessionID.map { try store.session(id: $0) } ?? store.recent(limit: 200)
                XCTAssertEqual(copy, Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.text) }), key)
            }
        }
        try store.append(row("same-id", session: "A", seconds: 0, text: "first A"))
        try store.append(row("keep-A", session: "A", seconds: 1))
        try store.append(row("remove-B", session: "B", seconds: 1))
        try poll()
        for session in ["B", "C", "B"] {
            try store.deleteTranscripts(ids: ["same-id"])
            try store.append(row("same-id", session: session, seconds: 0, text: "now \(session)"))
        }
        try store.append(row("new-A", session: "A", seconds: 2))
        try store.deleteTranscripts(ids: ["remove-B"])
        try poll()
        try store.deleteTranscripts(ids: ["same-id"])
        try poll()
        try store.append(row("same-id", session: "A", seconds: 3, text: "returned A"))
        try poll()
        try store.deleteTranscripts(ids: ["same-id"])
        try poll()
        let replay = try store.changes(since: 0, limit: 200)
        XCTAssertEqual(replay.deleted.filter { $0.id == "same-id" }.count, 1, "Global history replay coalesces deletions across sessions")
        for session in ["A", "B", "C"] {
            XCTAssertEqual(try store.changes(since: 0, sessionID: session).deleted.filter { $0.id == "same-id" }.count, 1)
        }
    }

    private func count(_ sql: String) throws -> Int {
        var db: OpaquePointer?; var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        guard sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.database("query failed") }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
