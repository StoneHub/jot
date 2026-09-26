import XCTest
import SQLite3
@testable import JotCore

final class CaptureRecoveryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-recovery-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testChunksLongCaptureWithoutSixtySecondLimitOrTailLoss() {
        let scheduler = CaptureChunkScheduler(sampleRate: 10, maximumSeconds: 3)
        let samples = Array(repeating: Float(1), count: 655)
        let result = scheduler.split(samples)
        XCTAssertEqual(result.chunks.count, 21)
        XCTAssertTrue(result.chunks.allSatisfy { $0.count == 30 })
        XCTAssertEqual(result.remainder.count, 25)
        XCTAssertEqual(result.chunks.reduce(0) { $0 + $1.count } + result.remainder.count, samples.count)
    }

    func testSilenceCanCloseAShortBoundedChunk() {
        let scheduler = CaptureChunkScheduler(sampleRate: 10, maximumSeconds: 3,
            minimumSeconds: 0.2, silenceSeconds: 0.7)
        XCTAssertFalse(scheduler.shouldFlush(bufferedSamples: 1, consecutiveSilentSamples: 7))
        XCTAssertTrue(scheduler.shouldFlush(bufferedSamples: 10, consecutiveSilentSamples: 7))
        XCTAssertTrue(scheduler.shouldFlush(bufferedSamples: 30, consecutiveSilentSamples: 0))
    }

    func testFailedAttemptHasRecoveryPriority() {
        let attempt = DictationAttempt(id: "attempt", sessionID: "session",
            startedAt: Date(), endedAt: Date(), text: "held words", state: .deliveryFailed)
        XCTAssertEqual(DictationRecovery.select(attempt: attempt, recentSpeech: "newer room speech"),
            RecoverySelection(text: "held words", source: .failedAttempt("attempt")))
    }

    func testDeliveredOrEmptyAttemptFallsBackToRecentSpeech() {
        let delivered = DictationAttempt(id: "attempt", sessionID: "session",
            startedAt: Date(), text: "already inserted", state: .delivered)
        XCTAssertEqual(DictationRecovery.select(attempt: delivered, recentSpeech: "recent words"),
            RecoverySelection(text: "recent words", source: .recentSpeech))
        XCTAssertNil(DictationRecovery.select(attempt: nil, recentSpeech: "  \n"))
    }

    func testAttemptTextAndStateSurviveReopeningAndDeletionClearsThem() throws {
        let attempt = DictationAttempt(id: "attempt", sessionID: "session", startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 105), text: "recover me", state: .deliveryUnverified,
            hasGap: true,
            updatedAt: Date(timeIntervalSince1970: 106))
        do { try TranscriptStore(directory: directory).saveDictationAttempt(attempt) }
        var reopened = try TranscriptStore(directory: directory)
        XCTAssertEqual(try reopened.latestRecoverableDictationAttempt(), attempt)
        try reopened.deleteSession(id: "session")
        XCTAssertNil(try reopened.latestRecoverableDictationAttempt())

        try reopened.saveDictationAttempt(attempt)
        try reopened.clearHistory()
        XCTAssertNil(try reopened.latestRecoverableDictationAttempt())
        reopened = try TranscriptStore(directory: directory)
        XCTAssertNil(try reopened.latestRecoverableDictationAttempt())
    }

    func testSchemaSixAttemptsMigrateWithoutInventingAGap() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("transcripts.sqlite3").path
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        let schemaSix = """
            CREATE TABLE dictation_attempts (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, started_at REAL NOT NULL,
                ended_at REAL, text TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('capturing','recognizing','ready','deliveryFailed','deliveryUnverified','delivered','discarded')),
                updated_at REAL NOT NULL
            );
            INSERT INTO dictation_attempts VALUES('old','session',100,105,'kept words','deliveryFailed',106);
            PRAGMA user_version=6;
            """
        XCTAssertEqual(sqlite3_exec(database, schemaSix, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try TranscriptStore(directory: directory)
        let migrated = try XCTUnwrap(store.latestRecoverableDictationAttempt())
        XCTAssertEqual(migrated.id, "old")
        XCTAssertFalse(migrated.hasGap)

        var reopened: OpaquePointer?
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &reopened), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(reopened, "SELECT has_gap FROM dictation_attempts WHERE id='old'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        statement = nil
        XCTAssertEqual(sqlite3_prepare_v2(reopened, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 8)
        sqlite3_finalize(statement)
        sqlite3_close(reopened)
    }

    func testRecoveryWindowUsesWordEvidenceAtBothEdges() throws {
        let store = try TranscriptStore(directory: directory)
        let row = Transcript(id: "row", sessionID: "session", startedAt: Date(timeIntervalSince1970: 100),
            startSeconds: 0, endSeconds: 6, text: "zero one two three", mode: "ambient")
        try store.append(row)
        try store.appendWords([
            StoredWord(transcriptID: "row", position: 0, word: "zero", startSeconds: 0, endSeconds: 1, probabilities: []),
            StoredWord(transcriptID: "row", position: 1, word: "one", startSeconds: 1.1, endSeconds: 2, probabilities: []),
            StoredWord(transcriptID: "row", position: 2, word: "two", startSeconds: 3, endSeconds: 4, probabilities: []),
            StoredWord(transcriptID: "row", position: 3, word: "three", startSeconds: 5, endSeconds: 6, probabilities: [])
        ])
        XCTAssertEqual(try store.recoveryText(from: Date(timeIntervalSince1970: 102.1),
            through: Date(timeIntervalSince1970: 105)), "two")
        XCTAssertEqual(try store.recoveryText(from: Date(timeIntervalSince1970: 101),
            through: Date(timeIntervalSince1970: 104)), "one two",
            "Words entirely outside a clip are excluded even when they touch its edge")
        XCTAssertEqual(try store.recoveryText(from: Date(timeIntervalSince1970: 102.1),
            through: Date(timeIntervalSince1970: 102.9)), "",
            "A window entirely between timed words must not pull in the whole row")
    }

    func testNewestUnverifiedAttemptTakesPriorityOverOlderFailedAttempt() throws {
        let store = try TranscriptStore(directory: directory)
        let older = DictationAttempt(sessionID: "session", startedAt: Date(timeIntervalSince1970: 100),
            text: "older failed", state: .deliveryFailed, updatedAt: Date(timeIntervalSince1970: 101))
        let newer = DictationAttempt(sessionID: "session", startedAt: Date(timeIntervalSince1970: 102),
            text: "newer unverified", state: .deliveryUnverified, updatedAt: Date(timeIntervalSince1970: 103))
        try store.saveDictationAttempt(older)
        try store.saveDictationAttempt(newer)
        XCTAssertEqual(try store.latestRecoverableDictationAttempt(), newer)
    }

    func testRecoveryWindowIncludesWholeLegacyRowRatherThanOmittingEdges() throws {
        let store = try TranscriptStore(directory: directory)
        try store.append(Transcript(id: "old", sessionID: "session", startedAt: Date(timeIntervalSince1970: 100),
            startSeconds: 0, endSeconds: 3, text: "legacy whole row", mode: "ambient"))
        XCTAssertEqual(try store.recoveryText(from: Date(timeIntervalSince1970: 102.9),
            through: Date(timeIntervalSince1970: 103)), "legacy whole row")
    }

    func testDeletingDictationTranscriptAlsoDeletesItsRecoveryAttempt() throws {
        let store = try TranscriptStore(directory: directory)
        let attempt = DictationAttempt(id: "attempt", sessionID: "session", startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101), text: "private words", state: .deliveryFailed,
            updatedAt: Date(timeIntervalSince1970: 102))
        try store.saveDictationAttempt(attempt)
        try store.append(Transcript(id: attempt.id, sessionID: attempt.sessionID, startedAt: attempt.startedAt,
            startSeconds: 0, endSeconds: 1, text: attempt.text, mode: "dictation"))
        try store.deleteTranscripts(ids: [attempt.id])
        XCTAssertNil(try store.latestRecoverableDictationAttempt())
        XCTAssertNil(try store.read(id: attempt.id))
    }

    func testDeletingBlankTapRemovesItsPersistedAttempt() throws {
        let store = try TranscriptStore(directory: directory)
        try store.saveDictationAttempt(DictationAttempt(id: "blank", sessionID: "session",
            startedAt: Date(timeIntervalSince1970: 100), state: .capturing,
            updatedAt: Date(timeIntervalSince1970: 101)))
        try store.deleteDictationAttempt(id: "blank")

        var database: OpaquePointer?
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcripts.sqlite3").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM dictation_attempts WHERE id='blank'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    func testInterruptedRecognizedAttemptBecomesFailedRecoveryOnReopen() throws {
        let store = try TranscriptStore(directory: directory)
        try store.saveDictationAttempt(DictationAttempt(id: "interrupted", sessionID: "session",
            startedAt: Date(timeIntervalSince1970: 100), text: "already recognized", state: .capturing,
            updatedAt: Date(timeIntervalSince1970: 105)))
        try store.finalizeInterruptedDictationAttempts(converting: { $0 })
        let attempt = try XCTUnwrap(store.latestRecoverableDictationAttempt())
        XCTAssertEqual(attempt.state, .deliveryFailed)
        XCTAssertEqual(attempt.endedAt, Date(timeIntervalSince1970: 105))
        XCTAssertEqual(attempt.text, "already recognized")
        XCTAssertTrue(attempt.hasGap)
    }
}
