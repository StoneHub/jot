import XCTest
import SQLite3
@testable import JotCore

/// Recent rows and Sessions fold in each recognition block's saved rows instead of reading the store again. Every fold must leave what a full read would return.
final class LibraryRowsTests: XCTestCase {
    private var directory: URL!
    /// A start time with sub-second digits, as the recognizer's clock gives, so a date that does not round-trip through the store shows.
    private let began = Date(timeIntervalSinceReferenceDate: 780_000_000.123_456_8)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-library-rows-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, session: String, at seconds: Double, speaker: String? = "S1", mode: String = "ambient", startedAt: Date? = nil) -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: startedAt ?? began, startSeconds: seconds, endSeconds: seconds + 1.5,
                   text: "text \(id)", speakerID: mode == "ambient" ? speaker : nil, mode: mode, speakerLabel: "stale name")
    }

    private func assertMatchesFullRead(_ rows: LibraryRows, _ store: TranscriptStore, _ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(rows.recent, try store.recent(limit: LibraryRows.recentLimit), "recent rows after \(step)", file: file, line: line)
        XCTAssertEqual(rows.sessions, try store.sessions(limit: LibraryRows.sessionLimit), "sessions after \(step)", file: file, line: line)
    }

    /// Saves one block's rows and folds them in, as the recognition worker does.
    private func block(_ saved: [Transcript], into rows: inout LibraryRows, _ store: TranscriptStore) throws {
        for transcript in saved { try store.append(transcript) }
        try rows.add(saved, savedTo: store)
    }

    func testFoldedBlocksMatchAFullReadThroughCleanupAndEdits() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<30 { try store.append(row("old-\(index)", session: "old-\(index % 3)", at: Double(index))) }
        try store.label(sessionID: "live", speakerID: "S2", name: "Ada")
        var rows = LibraryRows()
        try rows.readRecent(from: store); try rows.readSessions(from: store)
        try assertMatchesFullRead(rows, store, "the first read")

        // A new session, a block of two speakers, one named, and a dictation held during it, which Sessions leaves out.
        try block([row("a1", session: "live", at: 100), row("a2", session: "live", at: 101, speaker: "S2")], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a new session's first block")
        try block([row("a3", session: "live", at: 103), row("d1", session: "live", at: 102.5, mode: "dictation")], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a block with a dictation row")
        // Rows that start together order by id, and a row older than every recent one stays out of them but counts in its session.
        try block([row("a5", session: "live", at: 104), row("a4", session: "live", at: 104), row("late", session: "old-1", at: 0.5)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "tied and late rows")
        // A meeting names its session before any row is saved.
        try store.setTitle(sessionID: "meeting", title: "Standup")
        try rows.readSessions(from: store)
        try block([row("m1", session: "meeting", at: 110)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a titled session's first row")

        // Cleanup replaces the text of saved rows in place.
        let phrase = try store.session(id: "live").filter { $0.mode == "ambient" }.suffix(2).map { $0 }
        let cleaned = phrase.map { $0.text.uppercased() }
        XCTAssertTrue(try store.setReadablePhrase(cleaned, for: phrase))
        rows.replace(texts: Dictionary(uniqueKeysWithValues: zip(phrase.map(\.id), cleaned)))
        try assertMatchesFullRead(rows, store, "cleanup")

        // Edits outside a block read in full; blocks after them fold onto that read.
        try store.label(sessionID: "live", speakerID: "S1", name: "Grace")
        try rows.readRecent(from: store)
        try block([row("a6", session: "live", at: 120)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a speaker name, then a block")
        try store.deleteTranscripts(ids: ["a5", "m1"])
        try rows.readRecent(from: store); try rows.readSessions(from: store)
        try block([row("a7", session: "live", at: 121)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a delete, then a block")
        try store.deleteSession(id: "old-2")
        try store.setTitle(sessionID: "live", title: "Renamed")
        try rows.readRecent(from: store); try rows.readSessions(from: store)
        try block([row("a8", session: "live", at: 122, speaker: "S2")], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a session delete and a title, then a block")

        // A regroup splits a row in two.
        try store.append(row("w", session: "regroup", at: 130))
        try store.appendWords([StoredWord(transcriptID: "w", position: 0, word: "one", startSeconds: 130, endSeconds: 130.5, probabilities: []),
                               StoredWord(transcriptID: "w", position: 1, word: "two", startSeconds: 130.6, endSeconds: 131, probabilities: [])])
        XCTAssertTrue(try store.relabelSession("regroup", speakers: { _ in ["S1", "S2"] }))
        try rows.readRecent(from: store); try rows.readSessions(from: store)
        try block([row("a9", session: "live", at: 140)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a regroup, then a block")
    }

    func testAFullSessionListTakesANewSessionAndOneBeyondIt() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<(LibraryRows.sessionLimit + 5) {
            try store.append(row("r\(index)", session: String(format: "s%03d", index), at: Double(index) * 10))
        }
        var rows = LibraryRows()
        try rows.readRecent(from: store); try rows.readSessions(from: store)
        XCTAssertEqual(rows.sessions.count, LibraryRows.sessionLimit)
        try block([row("new", session: "fresh", at: 5_000)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a new session on a full list")
        // s000 fell off the list; a row late in it brings it back ahead of the rest.
        try block([row("back", session: "s000", at: 6_000)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a row for a session beyond the list")
        // Sessions that end together order by id.
        try block([row("tie-b", session: "tie-b", at: 7_000), row("tie-a", session: "tie-a", at: 7_000)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "two sessions ending together")
    }

    func testAFailedFoldReadsInFullOnTheNextBlock() throws {
        let store = try TranscriptStore(directory: directory)
        var rows = LibraryRows()
        try block([row("a", session: "live", at: 1)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a fold before any read")
        rename("speaker_labels", to: "hidden_labels")
        XCTAssertThrowsError(try block([row("b", session: "live", at: 2)], into: &rows, store))
        rename("hidden_labels", to: "speaker_labels")
        try block([row("c", session: "live", at: 3)], into: &rows, store)
        try assertMatchesFullRead(rows, store, "a failed fold, then a block")
    }

    func testDictationRowsFoldIntoTheDictationsPage() throws {
        let store = try TranscriptStore(directory: directory)
        for index in 0..<60 {
            try store.append(row("d\(index)", session: "dictation-\(index)", at: Double(index) * 3, mode: "dictation"))
            try store.append(row("a\(index)", session: "live", at: Double(index) * 3 + 1))
        }
        let page = 51
        var found = try store.recent(mode: "dictation", limit: page)
        for index in 60..<64 {
            let saved = [row("d\(index)", session: "dictation-\(index)", at: Double(index) * 3, mode: "dictation")]
            for transcript in saved { try store.append(transcript) }
            found = try LibraryRows.newest(LibraryRows.stored(saved, labels: store.labels(sessionID:)), merging: found, limit: page)
            XCTAssertEqual(found, try store.recent(mode: "dictation", limit: page))
        }
        let cleaned = ["d63": "Cleaned."]
        try store.setReadableText("Cleaned.", for: found[0])
        XCTAssertEqual(LibraryRows.replacing(cleaned, in: found), try store.recent(mode: "dictation", limit: page))
    }

    /// Issue #71: a block's main-thread work stays under a millisecond at 7,000 rows and does not grow when the store doubles. The full read it replaces is timed alongside for the record.
    func testABlockCostsUnderAMillisecondAndDoesNotGrowWithTheStore() throws {
        var medians: [Int: Double] = [:]
        for size in [7_000, 14_000] {
            let folder = directory.appendingPathComponent("\(size)")
            let store = try TranscriptStore(directory: folder)
            seed(size, into: folder)
            try store.label(sessionID: "live", speakerID: "S1", name: "Ada")
            var rows = LibraryRows()
            try rows.readRecent(from: store); try rows.readSessions(from: store)
            var folds: [Double] = [], reads: [Double] = []
            for index in 0..<60 {
                let saved = [row("block-\(index)-a", session: "live", at: 100_000 + Double(index) * 3),
                             row("block-\(index)-b", session: "live", at: 100_001 + Double(index) * 3, speaker: "S2")]
                for transcript in saved { try store.append(transcript) }
                let start = DispatchTime.now().uptimeNanoseconds
                try rows.add(saved, savedTo: store)
                folds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                // What each block read before: recent rows, events, the Dictations page and count, and Sessions.
                let before = DispatchTime.now().uptimeNanoseconds
                _ = try store.recent(limit: 20); _ = try store.events(limit: 50)
                _ = try store.recent(mode: "dictation", limit: 51); _ = try store.count(mode: "dictation")
                _ = try store.sessions(limit: 200)
                reads.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000)
            }
            try assertMatchesFullRead(rows, store, "60 blocks on \(size) rows")
            let fold = median(folds), read = median(reads)
            medians[size] = fold
            print(String(format: "LibraryRows at %d rows: fold %.3f ms per block (median of %d), full read %.3f ms", size, fold, folds.count, read))
            XCTAssertLessThan(fold, 1, "A block's fold took \(fold) ms at \(size) rows")
        }
        let small = medians[7_000]!, large = medians[14_000]!
        XCTAssertLessThan(large, small * 2 + 0.1, "A block's fold grew with the store: \(small) ms at 7,000 rows, \(large) ms at 14,000")
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// Writes `count` rows straight into the store's file in one transaction: ambient rows across 150 sessions with a dictation every tenth row.
    private func seed(_ count: Int, into folder: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("transcripts.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN", nil, nil, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO transcripts(id,session_id,started_at,start_seconds,end_seconds,text,speaker_id,mode) VALUES(?,?,?,?,?,?,?,?)", -1, &stmt, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for index in 0..<count {
            let dictation = index % 10 == 0
            let seconds = Double(index) * 4
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, "seed-\(index)", -1, transient)
            sqlite3_bind_text(stmt, 2, dictation ? "dictation-\(index)" : "seed-session-\(index % 150)", -1, transient)
            sqlite3_bind_double(stmt, 3, began.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, seconds)
            sqlite3_bind_double(stmt, 5, seconds + 3)
            sqlite3_bind_text(stmt, 6, "seeded row \(index) with a sentence of ordinary length for a spoken phrase", -1, transient)
            if dictation { sqlite3_bind_null(stmt, 7) } else { sqlite3_bind_text(stmt, 7, "S\(index % 3 + 1)", -1, transient) }
            sqlite3_bind_text(stmt, 8, dictation ? "dictation" : "ambient", -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
    }

    /// Renames a table over a second connection, so the store's next query of it fails, or works again.
    private func rename(_ name: String, to newName: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE \(name) RENAME TO \(newName)", nil, nil, nil), SQLITE_OK)
    }
}
