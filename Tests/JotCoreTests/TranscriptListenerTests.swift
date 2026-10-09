import XCTest
@testable import JotCore

final class TranscriptListenerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(_ id: String, _ text: String, at seconds: Double = 1, speaker: String? = "s1", session: String = "session", mode: String = "ambient") -> Transcript {
        .init(id: id, sessionID: session, startedAt: base, startSeconds: seconds, endSeconds: seconds + 1,
              text: text, speakerID: speaker, mode: mode)
    }
    private func follower(_ mode: TranscriptListenConfiguration.Mode = .command, phrases: [String] = ["claude"]) -> TranscriptListener {
        .init(configuration: .init(wakePhrases: phrases, mode: mode), subscribedAt: base)
    }
    private func page(_ rows: [Transcript], more: Bool = false) -> TranscriptChanges {
        .init(rows: rows.enumerated().map { .init($0.element, sequence: Int64($0.offset + 1)) }, cursor: 50, hasMore: more)
    }

    func testFastCutsAtWakePhraseAndEmitsOnlyOnceForCleanedID() throws {
        var listener = follower(.fast)
        let events = listener.consume(page([row("1", "background then CLAUDE, do this")]), at: 1)
        XCTAssertEqual(events.map(\.text), ["CLAUDE, do this"])
        XCTAssertEqual(listener.consume(page([row("1", "Claude, do this.")]), at: 3), [])
        XCTAssertEqual(listener.consume(page([row("2", "unaddressed chatter", at: 4)]), at: 4), [])
        XCTAssertEqual(listener.advance(at: 100), [])
        XCTAssertFalse(try XCTUnwrap(events.first).line().contains("\n"))
    }
    func testUnicodeBoundariesAndAliases() {
        var listener = follower(.fast, phrases: ["claude", "hey assistant"])
        let texts = ["claudette no", "éclaude no", "claude_thing no", "claude2 no", "hey   ASSISTANT, yes", "(Claude), yes"]
        let events = listener.consume(page(texts.enumerated().map { row(String($0.offset), $0.element, at: Double($0.offset + 1)) }), at: 1)
        XCTAssertEqual(events.map(\.text), ["hey   ASSISTANT, yes", "Claude), yes"])
    }
    func testMultiwordAliasCanSpanAdjacentRows() {
        var listener = follower(phrases: ["hey claude"])
        XCTAssertEqual(listener.consume(page([row("1", "background hey"), row("2", "Claude, start", at: 2)]), at: 1), [])
        XCTAssertEqual(listener.consume(page([row("1", "Background hey")]), at: 2), [])
        XCTAssertEqual(listener.advance(at: 7).map(\.text), ["hey Claude, start"])
    }
    func testPhraseDoesNotSpanSpeakersOrWideSpeechGap() {
        var listener = follower(.fast, phrases: ["hey claude"])
        XCTAssertEqual(listener.consume(page([row("1", "hey"), row("2", "Claude, no", at: 2, speaker: "s2"), row("3", "Claude, no", at: 20)]), at: 1), [])
    }
    func testCommandFoldsReplacementAndNewRowsAndDoesNotWaitForCleanup() {
        var listener = follower()
        XCTAssertEqual(listener.consume(page([row("1", "noise Claude do"), row("2", "the task", at: 2)]), at: 1), [])
        XCTAssertEqual(listener.consume(page([row("1", "Noise Claude, do")]), at: 5), [])
        XCTAssertEqual(listener.advance(at: 6), [])
        let event = listener.advance(at: 7)
        XCTAssertEqual(event.map(\.text), ["Claude, do the task"])
        XCTAssertEqual(event.first?.rowIDs, ["1", "2"])
        XCTAssertEqual(listener.consume(page([row("1", "Claude, do."), row("2", "Claude, the task.", at: 2)]), at: 8), [])
        XCTAssertEqual(listener.advance(at: 100), [])
    }
    func testNewSpeakerFinishesCommandAndCanWakeAnother() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude first")]), at: 1)
        XCTAssertEqual(listener.consume(page([row("2", "Claude second", at: 2, speaker: "s2")]), at: 2).map(\.text), ["Claude first"])
        XCTAssertEqual(listener.advance(at: 8).map(\.text), ["Claude second"])
    }
    func testNewSessionFinishesCommand() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude first")]), at: 1)
        XCTAssertEqual(listener.consume(page([row("2", "unaddressed", session: "other")]), at: 2).map(\.text), ["Claude first"])
    }
    func testCleanupRemovingWakeCancelsPendingCommand() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude mistaken")]), at: 1)
        _ = listener.consume(page([row("1", "cloud mistaken")]), at: 2)
        XCTAssertEqual(listener.advance(at: 100), [])
    }
    func testCleanupCanSupplyPreviouslyMisrecognizedWakeOnce() {
        var listener = follower(.fast)
        _ = listener.consume(page([row("1", "cloud do it")]), at: 1)
        XCTAssertEqual(listener.consume(page([row("1", "Claude do it")]), at: 2).map(\.text), ["Claude do it"])
        XCTAssertEqual(listener.consume(page([row("1", "Claude, do it.")]), at: 3), [])
    }
    func testContextSeedsHistoryWithoutWakingAndKeepsReplacements() {
        var listener = follower(.context)
        listener.seedContext([row("history", "Claude historical", at: -20), row("old", "outside window", at: -500)])
        _ = listener.consume(page([row("history", "Clean historical.", at: -20), row("1", "noise Claude use context")]), at: 1)
        let result = listener.advance(at: 7).first
        XCTAssertEqual(result?.text, "Claude use context")
        XCTAssertEqual(result?.context?.map(\.text), ["Clean historical."])
    }
    func testDeletionUpdatesPendingAndContext() {
        var listener = follower(.context)
        listener.seedContext([row("history", "prior", at: -10)])
        _ = listener.consume(page([row("1", "Claude use"), row("2", "remove this", at: 2)]), at: 1)
        _ = listener.consume(.init(rows: [], cursor: 52, hasMore: false, deleted: [
            .init(id: "history", sessionID: "session", sequence: 51), .init(id: "2", sessionID: "session", sequence: 52)]), at: 2)
        let result = listener.advance(at: 7).first
        XCTAssertEqual(result?.text, "Claude use")
        XCTAssertEqual(result?.context, [])
    }
    func testDeletingAnchorCancels() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude use")]), at: 1)
        _ = listener.consume(.init(rows: [], cursor: 2, hasMore: false, deleted: [.init(id: "1", sessionID: "session", sequence: 2)]), at: 2)
        XCTAssertEqual(listener.advance(at: 100), [])
    }
    func testResetDiscardsPendingAndReplay() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude old")]), at: 1)
        XCTAssertEqual(listener.consume(.init(rows: [.init(row("new", "Claude replay"), sequence: 1)], cursor: 1, hasMore: false, reset: true), at: 2), [])
        XCTAssertEqual(listener.advance(at: 100), [])
        XCTAssertEqual(listener.retainedRows, 0)
    }
    func testAllShowsReplacementsDeletesAndResetInSequenceOrder() {
        var listener = follower(.all)
        XCTAssertEqual(listener.consume(page([row("1", "raw")]), at: 1).first?.text, "raw")
        let changes = TranscriptChanges(rows: [.init(row("2", "new"), sequence: 4), .init(row("1", "clean"), sequence: 2)], cursor: 4, hasMore: false,
                                       deleted: [.init(id: "1", sessionID: "session", sequence: 3)])
        let events = listener.consume(changes, at: 2)
        XCTAssertEqual(events.map(\.event), ["row", "deleted", "row"])
        XCTAssertEqual(events.map(\.id), ["1", "1", "2"])
        XCTAssertEqual(listener.consume(.init(rows: [], cursor: 0, hasMore: false, reset: true), at: 3).map(\.event), ["reset"])
    }
    func testHistoryAndDictationCopiesNeverWake() {
        var listener = follower(.fast)
        XCTAssertEqual(listener.consume(page([row("old", "Claude old", at: -50), row("copy", "Claude dictation", mode: "dictation")]), at: 1), [])
    }
    func testPauseFlushesAndPrintsNotice() {
        var listener = follower()
        _ = listener.consume(page([row("1", "Claude finish")]), at: 1)
        XCTAssertEqual(listener.pause().map(\.event), ["command", "paused"])
        XCTAssertEqual(listener.advance(at: 100), [])
    }
    func testOutputIsOneLineEvenForControlsAndNewlines() throws {
        let line = try TranscriptListenEvent(event: "command", text: "Claude\nfirst\rsecond\u{0}third").line()
        XCTAssertTrue(line.hasPrefix("jot: "))
        XCTAssertFalse(line.contains("\n")); XCTAssertFalse(line.contains("\r")); XCTAssertFalse(line.contains("\u{0}"))
    }
    func testMemoryIsBoundedAndEvictedWakeCannotRetrigger() {
        var listener = follower(.fast)
        let wake = row("wake", "Claude original")
        XCTAssertEqual(listener.consume(page([wake]), at: 1).count, 1)
        let rows = (2...2200).map { row(String($0), String(repeating: "ambient ", count: 40), at: Double($0)) }
        _ = listener.consume(page(rows), at: 2)
        XCTAssertLessThanOrEqual(listener.retainedRows, TranscriptListener.maximumRows)
        XCTAssertLessThanOrEqual(listener.retainedTextBytes, TranscriptListener.maximumTextBytes)
        XCTAssertEqual(listener.consume(page([wake]), at: 3), [])
    }
    func testOversizedCommandProducesOneMarkedPartialEvent() {
        var listener = follower()
        var rows = [row("wake", "Claude " + String(repeating: "a", count: 9000))]
        rows += (2...6).map { row(String($0), String(repeating: "b", count: 8192), at: Double($0)) }
        let events = listener.consume(page(rows), at: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.truncated, true)
        XCTAssertLessThanOrEqual(events.first?.text?.utf8.count ?? 0, TranscriptListener.maximumCommandBytes)
        XCTAssertEqual(listener.advance(at: 100), [])
    }
    func testConfigurationBoundsAndInvalidAliasesFallBack() {
        let config = TranscriptListenConfiguration(wakePhrases: [""], quietGap: .nan, lookbackMinutes: 100)
        XCTAssertEqual(config.wakePhrases, ["claude"]); XCTAssertEqual(config.quietGap, 6); XCTAssertEqual(config.lookbackMinutes, 60)
        XCTAssertNil(TranscriptListenConfiguration.phrases("claude,,cloud"))
        XCTAssertNil(TranscriptListenConfiguration.phrases(","))
    }
    func testNewSplitIDsCannotRepeatAnEmittedWakeButNewSpeechCan() {
        for mode in [TranscriptListenConfiguration.Mode.fast, .command, .context] {
            var listener = follower(mode)
            var emitted = listener.consume(page([row("parent", "Claude original", at: 1)]), at: 1)
            emitted += listener.advance(at: 7)
            XCTAssertEqual(emitted.count, 1)
            let split = TranscriptChanges(rows: [.init(row("child", "Claude original", at: 1, speaker: "new-speaker"), sequence: 3)], cursor: 3, hasMore: false,
                deleted: [.init(id: "parent", sessionID: "session", sequence: 2)])
            XCTAssertEqual(listener.consume(split, at: 8), [])
            XCTAssertEqual(listener.advance(at: 100), [])
            var fresh = listener.consume(page([row("fresh", "Claude next", at: 4)]), at: 101)
            fresh += listener.advance(at: 107)
            XCTAssertEqual(fresh.map(\.text), ["Claude next"])
        }
    }
    func testHistoricalRowCannotAppendToPendingCommand() {
        var listener = TranscriptListener(subscribedAt: base.addingTimeInterval(10))
        _ = listener.consume(page([row("live", "Claude current", at: 11)]), at: 1)
        _ = listener.consume(page([row("old", "historical rewrite", at: 1)]), at: 2)
        XCTAssertEqual(listener.advance(at: 7).map(\.text), ["Claude current"])
    }
    func testGlobalIDMovesAcrossSessionsWithoutStaleContext() {
        var listener = follower(.context)
        listener.seedContext([row("move", "old session text", at: -10, session: "old")])
        _ = listener.consume(page([row("move", "new session text", at: -5, session: "new"), row("live", "Claude use context")]), at: 1)
        let event = listener.advance(at: 7).first
        XCTAssertEqual(event?.context?.map(\.text), ["new session text"])
    }
    func testCommandRowCountIsBoundedEvenForEmptyContinuations() {
        var listener = follower()
        let rows = [row("wake", "Claude go")] + (2...400).map { row(String($0), "", at: Double($0)) }
        let events = listener.consume(page(rows), at: 1)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.truncated, true)
        XCTAssertLessThanOrEqual(events.first?.rowIDs?.count ?? 0, TranscriptListener.maximumCommandRows)
        XCTAssertLessThanOrEqual(listener.retainedRows, TranscriptListener.maximumRows)
    }
    func testSettingsExposeListenerDefaultsWithoutSavedPreferences() throws {
        let defaults = MemoryDefaults()
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.text(JotSettings.listenWakePhrases), "claude")
        XCTAssertEqual(settings.text(JotSettings.listenMode), "command")
        XCTAssertEqual(settings.double(JotSettings.listenQuietGap), 6)
        XCTAssertEqual(settings.int(JotSettings.listenLookbackMinutes), 5)
        for key in [JotSettings.listenWakePhrases, JotSettings.listenMode, JotSettings.listenQuietGap, JotSettings.listenLookbackMinutes] {
            XCTAssertFalse(settings.isChanged(key))
        }
    }
}
