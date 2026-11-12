import XCTest
@testable import JotCore

/// The file on disk is unreadable without its key; the plaintext file an earlier build wrote becomes one, once, with every row.
final class StoreEncryptionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-encryption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var databaseURL: URL { directory.appendingPathComponent("transcripts.sqlite3") }

    private func transcript(_ id: String, _ text: String) -> Transcript {
        Transcript(id: id, sessionID: "s1", startedAt: Date(timeIntervalSince1970: 100), startSeconds: 0, endSeconds: 1, text: text, mode: "ambient")
    }

    func testANewStoreIsNotPlaintextAndNeedsItsKey() throws {
        let key = StoreKey.random()
        do {
            let store = try TranscriptStore(directory: directory, key: key)
            try store.append(transcript("a1", "the quick brown fox"))
        }
        XCTAssertFalse(try StoreEncryption.isPlaintext(databaseURL))
        XCTAssertNil(try Data(contentsOf: databaseURL).range(of: Data("quick brown".utf8)), "Transcript text is not on disk in the clear")
        XCTAssertEqual(try TranscriptStore(directory: directory, key: key).recent().map(\.text), ["the quick brown fox"])
        // Read after that reopen closed: every page is re-encrypted with a fresh nonce when it is rewritten, so the comparison needs the final bytes.
        let bytes = try Data(contentsOf: databaseURL)
        XCTAssertThrowsError(try TranscriptStore(directory: directory, key: StoreKey.random())) { error in
            XCTAssertTrue(error.localizedDescription.contains("history key"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("preserved"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), bytes, "A wrong key changes nothing")
        XCTAssertTrue(try TranscriptStore.hasEncryptedDatabase(in: directory))
        XCTAssertFalse(try TranscriptStore.hasEncryptedDatabase(in: directory.appendingPathComponent("none")))
    }

    func testThePlaintextFileAnEarlierBuildWroteIsEncryptedInPlaceWithEveryRow() throws {
        // What 0.3.7 wrote: format 8, plaintext, WAL, with a feed sequence past its last row after a delete. Built with
        // this build's schema over a nil key, which is how the migration itself reads the old file; DatabaseFormatTests
        // opens the files earlier builds really wrote.
        do {
            let plain = try SQLiteConnection(url: databaseURL, key: nil)
            try plain.execute("PRAGMA foreign_keys=ON")
            try plain.transaction {
                try plain.execute(TranscriptStore.schema)
                try plain.execute(TranscriptChangeFeed.schema)
                try plain.execute("PRAGMA user_version=8")
            }
            try plain.execute("INSERT INTO transcripts VALUES('a1','s1',100,0,1,'first words','speaker-1','ambient'); INSERT INTO transcripts VALUES('a2','s1',100,1,2,'second words',NULL,'ambient'); INSERT INTO transcripts VALUES('gone','s1',100,2,3,'deleted words',NULL,'ambient'); DELETE FROM transcripts WHERE id='gone'; INSERT INTO speaker_labels VALUES('s1','speaker-1','Gina'); INSERT INTO people VALUES('p1','Ada',X'000000000000803F',3,50,60); INSERT INTO usage_counters VALUES('2026-01-01','dictation.finished',4);")
            plain.close()
        }
        XCTAssertTrue(try StoreEncryption.isPlaintext(databaseURL))
        try Data("half an old attempt".utf8).write(to: URL(fileURLWithPath: databaseURL.path + StoreEncryption.workSuffix))

        let key = StoreKey.random()
        let store = try TranscriptStore(directory: directory, key: key)
        XCTAssertFalse(try StoreEncryption.isPlaintext(databaseURL))
        XCTAssertEqual(try store.recent().map(\.text), ["second words", "first words"])
        XCTAssertEqual(try store.recent().map(\.speakerLabel), [nil, "Gina"])
        XCTAssertEqual(try PeopleStore(sharing: store).list().map(\.name), ["Ada"])
        XCTAssertEqual(try store.usageCounts(from: "2026-01-01", through: "2026-01-01"), ["2026-01-01": ["dictation.finished": 4]])
        let feed = try store.changes(since: 0)
        XCTAssertEqual(feed.rows.map(\.transcript.id), ["a1", "a2"])
        XCTAssertEqual(feed.deleted.map(\.id), ["gone"], "Tombstones survive")
        // The AUTOINCREMENT counter came along, so a cursor an agent held before the launch still points past every old sequence.
        try store.append(transcript("a3", "third words"))
        let next = try store.changes(since: feed.cursor, generation: feed.generation)
        XCTAssertEqual(next.rows.map(\.transcript.id), ["a3"])
        XCTAssertGreaterThan(next.cursor, feed.cursor)
        for suffix in [StoreEncryption.workSuffix, "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + suffix), suffix)
        }
        XCTAssertEqual(try TranscriptStore(directory: directory, key: key).recent().count, 3, "Reopening does not migrate again")
        XCTAssertThrowsError(try TranscriptStore(directory: directory, key: StoreKey.random()))
        let permissions = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testAnEmptyOrHeaderOnlyFileBecomesANewStore() throws {
        try Data().write(to: databaseURL)
        _ = try TranscriptStore(directory: directory, key: .scratch)
        XCTAssertFalse(try StoreEncryption.isPlaintext(databaseURL))
        XCTAssertEqual(try TranscriptStore(directory: directory, key: .scratch).recent().count, 0)
    }

    func testKeysRoundTripThroughTheTextSettingsShows() throws {
        let key = StoreKey.random()
        XCTAssertEqual(key.hex.count, 64 + 15, "Sixteen groups of four digits")
        XCTAssertEqual(try StoreKey(hex: key.hex), key)
        XCTAssertEqual(try StoreKey(hex: key.hex.uppercased().replacingOccurrences(of: " ", with: "-")), key)
        XCTAssertThrowsError(try StoreKey(hex: String(key.hex.dropLast())))
        XCTAssertThrowsError(try StoreKey(hex: key.hex.replacingOccurrences(of: "a", with: "g")))
        XCTAssertThrowsError(try StoreKey(bytes: Data(count: 31)))
        XCTAssertNotEqual(StoreKey.random(), StoreKey.random())
        XCTAssertFalse(key.keyStatement.contains(" "), "A pragma value is one token")
        XCTAssertEqual(key.keyStatement, "PRAGMA key = \"x'\(key.rawHex)'\"")
    }

    func testOtherConnectionsToTheStoreUseItsKey() throws {
        let key = StoreKey.random()
        let store = try TranscriptStore(directory: directory, key: key)
        let pass = try SpeakerPassStore(sharing: store)
        try pass.replace(sessionID: "s1", result: SpeakerPassResult(segments: [(speaker: "speaker-1", start: 0, end: 1)], speakers: ["speaker-1": [1, 0]], durationSeconds: 1, processingSeconds: 0))
        XCTAssertEqual(try pass.speakers(sessionID: "s1").map(\.speakerID), ["speaker-1"])
        try StoreCheckAccess.execute("CREATE TABLE check_marker(x)", in: directory, key: key)
        XCTAssertThrowsError(try StoreCheckAccess.execute("CREATE TABLE other(x)", in: directory, key: StoreKey.random()))
    }
}
