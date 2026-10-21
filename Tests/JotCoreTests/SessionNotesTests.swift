import XCTest
@testable import JotCore

@MainActor
final class SessionNotesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ id: String, at seconds: Double, speaker: String, _ text: String) -> Transcript {
        Transcript(id: id, sessionID: "s1", startedAt: start, startSeconds: seconds, endSeconds: seconds + 4, text: text,
                   speakerID: speaker, mode: "ambient", speakerLabel: speaker == "S1" ? "Ana" : nil)
    }
    private let reply = "## Summary\nPlanned the launch.\n\n## Decisions\n- Ship Friday\n\n## Action items\n- Ana writes the notes"

    func testShortSessionIsOnePartWithTimesAndSpeakers() async throws {
        let rows = [row("a", at: 0, speaker: "S1", "We ship Friday."), row("b", at: 30, speaker: "S2", "I will test it.")]
        let parts = SessionNotes.parts(rows)
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].contains("Ana: We ship Friday."), parts[0])
        XCTAssertTrue(parts[0].contains("I will test it."))
        var requests: [ModelRequest] = []
        let notes = try await SessionNotes.write(rows) { requests.append($0); return .output("  \(self.reply)\n") }
        XCTAssertEqual(notes, SessionNotes.Notes(text: reply, parts: 1))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].instructions, SessionNotes.instructions)
        XCTAssertTrue(requests[0].prompt.hasPrefix("Transcript:\n\"\"\"\n"))
    }

    func testLongSessionIsNotedInPartsCutAtTurnsThenCombined() async throws {
        let sentence = String(repeating: "word ", count: 300) // about 1,500 bytes per turn
        let rows = (0..<12).map { row("r\($0)", at: Double($0) * 60, speaker: $0.isMultiple(of: 2) ? "S1" : "S2", sentence) }
        let parts = SessionNotes.parts(rows)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= SessionNotes.partBytes })
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("[") }, "Each part starts at a turn")
        var requests: [ModelRequest] = []
        let notes = try await SessionNotes.write(rows) { request in
            requests.append(request)
            return .output(request.instructions == SessionNotes.combineInstructions ? "combined" : "part")
        }
        XCTAssertEqual(notes, SessionNotes.Notes(text: "combined", parts: parts.count))
        XCTAssertEqual(requests.count, parts.count + 1)
        XCTAssertTrue(requests[1].prompt.hasPrefix("Part 2 of \(parts.count) of the transcript:"))
        XCTAssertTrue(requests.last!.prompt.contains("Notes for part \(parts.count):"))
    }

    func testOneOverlongTurnIsCutBetweenWords() {
        let rows = [row("a", at: 0, speaker: "S1", String(repeating: "longword ", count: 2_000))]
        let parts = SessionNotes.parts(rows)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= SessionNotes.partBytes && !$0.hasSuffix(" ") })
    }

    func testTooLongEmptyAndFailedSessionsSayWhy() async throws {
        let turn = String(repeating: "word ", count: 1_500)
        let long = (0..<(SessionNotes.maximumParts + 2)).map { row("r\($0)", at: Double($0) * 60, speaker: "S1", turn) }
        for (rows, result, message) in [
            (long, ModelCallResult.output("x"), "too long for notes"),
            ([row("a", at: 0, speaker: "S1", "  ")], .output("x"), "Nothing was said"),
            ([row("a", at: 0, speaker: "S1", "Hi")], .output(" \n "), "no notes"),
            ([row("a", at: 0, speaker: "S1", "Hi")], .timedOut, "did not answer"),
            ([row("a", at: 0, speaker: "S1", "Hi")], .unavailable("unauthorized"), "unavailable (unauthorized)"),
            ([row("a", at: 0, speaker: "S1", "Hi")], .blocked, "already writing notes"),
        ] {
            do {
                _ = try await SessionNotes.write(rows) { _ in result }
                XCTFail("Expected \(message)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription)
            }
        }
    }

    func testRepliesAreTrimmedAndBounded() {
        XCTAssertNil(SessionNotes.accepted("   "))
        let long = Array(repeating: String(repeating: "a", count: 99), count: 400).joined(separator: "\n")
        let kept = SessionNotes.accepted(long)
        XCTAssertLessThanOrEqual(kept?.utf8.count ?? .max, SessionNotes.maximumNotesBytes)
        XCTAssertTrue(kept?.hasSuffix(String(repeating: "a", count: 99)) == true, "Cut at a line break")
    }
}
