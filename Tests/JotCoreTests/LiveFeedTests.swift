import XCTest
@testable import JotCore

final class LiveFeedTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func row(_ id: String, _ seconds: Double, _ text: String, speaker: String? = "speaker-1", session: String = "live") -> Transcript {
        Transcript(id: id, sessionID: session, startedAt: start, startSeconds: seconds, endSeconds: seconds + 1, text: text, speakerID: speaker, mode: "ambient")
    }

    /// What a full read shows: the session in the store's order, grouped by the batch rules.
    private func fullRead(_ rows: [Transcript], gap: Double = 1.5) -> [String] {
        let ordered = rows.sorted { ($0.startedAt.addingTimeInterval($0.startSeconds), $0.id) < ($1.startedAt.addingTimeInterval($1.startSeconds), $1.id) }
        return lines(TranscriptExport.paragraphs(TranscriptGrouping.foldContinuations(ordered, gap: gap), mergeWithin: gap))
    }

    private func lines(_ paragraphs: [Transcript]) -> [String] {
        paragraphs.map { "\($0.id) \(TranscriptExport.speakerName($0)) \($0.startSeconds)-\($0.endSeconds): \($0.text)" }
    }

    func testShowGroupsTheSessionLikeAFullRead() {
        let rows = [row("a", 0, "We should ship"), row("b", 1.2, "on Friday."), row("c", 2.5, "and then", speaker: nil), row("d", 4, "Sounds good.", speaker: "speaker-2")]
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: rows.reversed(), labels: [:], gap: 1.5)
        XCTAssertEqual(feed.sessionID, "live")
        XCTAssertEqual(lines(feed.paragraphs), fullRead(rows))
        XCTAssertEqual(feed.paragraphs.map(\.text), ["We should ship on Friday.", "and then", "Sounds good."])
    }

    func testAppendAddsRowsOfTheShownSessionOnly() {
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: [row("a", 0, "We should ship")], labels: [:], gap: 1.5)
        let shown = feed.revision
        feed.append([row("b", 1.2, "on Friday."), row("x", 1.5, "elsewhere", session: "other")])
        XCTAssertEqual(feed.paragraphs.map(\.text), ["We should ship on Friday."])
        XCTAssertEqual(feed.revision, shown + 1)
        XCTAssertEqual(feed.cleanupRevision, 0)
        feed.append([row("y", 9, "still elsewhere", session: "other")])
        XCTAssertEqual(feed.revision, shown + 1)
    }

    func testAppendedRowTakesTheSpeakerNameAndFinishesTheSentence() {
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: [row("a", 0, "We should ship")], labels: ["speaker-1": "Ada"], gap: 1.5)
        feed.append([row("b", 1.2, "on Friday.", speaker: nil), row("c", 5, "Then we rest.")])
        XCTAssertEqual(feed.paragraphs.map(TranscriptExport.speakerName), ["Ada", "Ada"])
        XCTAssertEqual(feed.paragraphs.map(\.text), ["We should ship on Friday.", "Then we rest."])
    }

    func testRowSavedLateLandsAtItsSpokenTime() {
        var feed = LiveFeed()
        let rows = [row("a", 0, "First."), row("c", 10, "Third.")]
        feed.show(sessionID: "live", rows: rows, labels: [:], gap: 1.5)
        // A dictation row is saved after the speech around it, with its own start time and an offset of zero.
        let dictation = Transcript(id: "b", sessionID: "live", startedAt: start.addingTimeInterval(5), startSeconds: 0, endSeconds: 2, text: "Second.", mode: "dictation")
        feed.append([dictation])
        XCTAssertEqual(feed.paragraphs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(lines(feed.paragraphs), fullRead(rows + [dictation]))
    }

    /// The store breaks a tie in start time by id, so a row appended at the same moment as a shown row goes before it when its id sorts first.
    func testRowAtTheSameTimeGoesInIdOrder() {
        var feed = LiveFeed()
        let shown = row("b", 1, "Second.")
        feed.show(sessionID: "live", rows: [shown], labels: [:], gap: 1.5)
        let appended = row("a", 1, "First.")
        feed.append([appended])
        XCTAssertEqual(lines(feed.paragraphs), fullRead([shown, appended]))
        XCTAssertEqual(feed.paragraphs.map(\.id), ["a", "b"])
    }

    func testCleanedTextReplacesRawTextInPlace() {
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: [row("a", 0, "um we should ship"), row("b", 1.2, "on friday"), row("c", 5, "Next item.", speaker: "speaker-2")], labels: [:], gap: 1.5)
        feed.replace(texts: ["b": "on Friday."])
        XCTAssertEqual(feed.paragraphs.map(\.text), ["um we should ship on Friday.", "Next item."])
        feed.replace(texts: ["a": "We should ship"])
        XCTAssertEqual(feed.paragraphs.map(\.id), ["a", "c"])
        XCTAssertEqual(feed.paragraphs.map(\.text), ["We should ship on Friday.", "Next item."])
        XCTAssertEqual(feed.cleanupRevision, 2)
        let revision = feed.revision
        feed.replace(texts: ["gone": "Nothing."])
        XCTAssertEqual(feed.cleanupRevision, 2)
        XCTAssertEqual(feed.revision, revision)
    }

    func testCleanupThatEndsASentenceRegroupsTheRowsAfterIt() {
        var feed = LiveFeed()
        let rows = [row("a", 0, "we should ship"), row("b", 1.2, "on friday", speaker: nil)]
        feed.show(sessionID: "live", rows: rows, labels: [:], gap: 1.5)
        XCTAssertEqual(feed.paragraphs.map(TranscriptExport.speakerName), ["Speaker 1"])
        feed.replace(texts: ["a": "We should ship."])
        var cleaned = rows
        cleaned[0].text = "We should ship."
        XCTAssertEqual(lines(feed.paragraphs), fullRead(cleaned))
        XCTAssertEqual(feed.paragraphs.map(TranscriptExport.speakerName), ["Speaker 1", "Unattributed"])
    }

    func testNewSessionClearsTheFeed() {
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: [row("a", 0, "Old words.")], labels: ["speaker-1": "Ada"], gap: 1.5)
        feed.show(sessionID: "next", rows: [], labels: [:], gap: 1.5)
        XCTAssertEqual(feed.sessionID, "next")
        XCTAssertTrue(feed.paragraphs.isEmpty)
        feed.append([row("b", 1, "Late words.")])
        XCTAssertTrue(feed.paragraphs.isEmpty)
        feed.append([row("c", 1, "New words.", session: "next")])
        XCTAssertEqual(feed.paragraphs.map(TranscriptExport.speakerName), ["Speaker 1"])
    }

    /// A seeded mix of appends, late rows, and cleanups; after every step the feed must match a full read of the same rows.
    func testEveryChangeMatchesAFullRead() {
        var random = SeededGenerator(state: 56)
        let speakers: [String?] = ["speaker-1", "speaker-2", nil, "overlap"]
        let labels = ["speaker-2": "Bo"]
        var saved: [Transcript] = []
        var feed = LiveFeed()
        feed.show(sessionID: "live", rows: [], labels: labels, gap: 1.5)
        var clock = 0.0
        for step in 0..<400 {
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<6:
                clock += Double.random(in: 0.1...2.5, using: &random)
                var next = row("row-\(step)", clock, Bool.random(using: &random) ? "and so on" : "That is all.", speaker: speakers.randomElement(using: &random)!)
                feed.append([next])
                next.speakerLabel = next.speakerID.flatMap { labels[$0] }
                saved.append(next)
            case 6:
                let late = Transcript(id: "late-\(step)", sessionID: "live", startedAt: start.addingTimeInterval(Double.random(in: 0...clock, using: &random)), startSeconds: 0, endSeconds: 1, text: "A dictation.", mode: "dictation")
                feed.append([late])
                saved.append(late)
            default:
                guard !saved.isEmpty else { continue }
                var texts: [String: String] = [:]
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    let index = Int.random(in: max(0, saved.count - 12)..<saved.count, using: &random)
                    let text = ["Cleaned.", "cleaned words", ""].randomElement(using: &random)!
                    saved[index].text = text
                    texts[saved[index].id] = text
                }
                feed.replace(texts: texts)
            }
            XCTAssertEqual(lines(feed.paragraphs), fullRead(saved), "after step \(step)")
        }
    }
}

/// A fixed sequence of numbers, so a failure repeats.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
