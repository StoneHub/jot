import XCTest
@testable import JotCore

/// Pins what the suggestion card shows for each model result. The wording matches what SuggestionCoordinator showed
/// before the decision moved here.
final class SuggestionPresentationTests: XCTestCase {
    private func decide(_ result: ModelCallResult, mode: SuggestionMode, draft: SuggestionDraftSnapshot, before: String = "",
                        seed: SuggestionSeed? = nil, placeholder: String? = nil, context: String? = nil,
                        singleLine: Bool = false) -> SuggestionPresentation {
        SuggestionPresentation.decide(result, mode: mode, singleLine: singleLine, draft: draft, before: before, seed: seed,
                                      placeholder: placeholder, context: context)
    }

    private func blank() throws -> SuggestionDraftSnapshot { try XCTUnwrap(SuggestionDraftSnapshot(value: "", location: 0, length: 0)) }

    func testReplyShowsTheReplyCard() throws {
        XCTAssertEqual(decide(.output("Sounds good, see you at three."), mode: .reply, draft: try blank()),
                       .card(candidate: "Sounds good, see you at three.", title: "Suggested reply", action: "Tab to insert"))
    }

    func testContinuationCardKeepsTheLeadingSpaceItInserts() throws {
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "We should meet", location: 14, length: 0))
        XCTAssertEqual(decide(.output("on Friday."), mode: .continuation, draft: draft, before: draft.before),
                       .card(candidate: " on Friday.", title: "Suggested continuation", action: "Tab to insert at the cursor"))
    }

    func testContinuationThatOnlyRepeatsTheTextIsANotice() throws {
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "We should meet", location: 14, length: 0))
        XCTAssertEqual(decide(.output("We should meet"), mode: .continuation, draft: draft, before: draft.before),
                       .notice(text: "No suggestion: the result only repeated your text.", reason: "unchanged"))
    }

    func testDraftCardNamesSelectionOrNotes() throws {
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "fix teh bug", location: 0, length: 11))
        let selection = SuggestionSeed(text: "fix teh bug", location: 0, length: 11, isSelection: true)
        XCTAssertEqual(decide(.output("Fix the bug."), mode: .draft, draft: draft, seed: selection),
                       .card(candidate: "Fix the bug.", title: "Rewrite of your selection", action: "Tab to replace the selection"))
        let notes = SuggestionSeed(text: "fix teh bug", location: 0, length: 11, isSelection: false)
        XCTAssertEqual(decide(.output("Fix the bug."), mode: .draft, draft: draft, seed: notes),
                       .card(candidate: "Fix the bug.", title: "Draft from your notes", action: "Tab to replace your notes"))
    }

    func testUnchangedDraftSaysTheSelectionReadsWell() throws {
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "fix teh bug", location: 0, length: 11))
        let seed = SuggestionSeed(text: "fix teh bug", location: 0, length: 11, isSelection: true)
        XCTAssertEqual(decide(.output("fix teh bug."), mode: .draft, draft: draft, seed: seed),
                       .notice(text: "Your selection already reads well. No changes suggested.", reason: "unchanged"))
    }

    func testHintRestatementAsksForNotesOnlyInABlankField() throws {
        XCTAssertEqual(decide(.output("Ask Codex anything"), mode: .reply, draft: try blank(), placeholder: "Ask Codex anything"),
                       .notice(text: SuggestionPresentation.needsNotes, reason: "restates-hint"))
        let typed = try XCTUnwrap(SuggestionDraftSnapshot(value: "hi", location: 2, length: 0))
        XCTAssertEqual(decide(.output("Ask Codex anything"), mode: .reply, draft: typed, placeholder: "Ask Codex anything"),
                       .notice(text: "No suggestion: the result only repeated the field's hint.", reason: "restates-hint"))
    }

    func testCopiedScreenTextIsANotice() throws {
        XCTAssertEqual(decide(.output("Can you send me the quarterly report by Friday afternoon"), mode: .reply, draft: try blank(),
                              context: "Can you send me the quarterly report by Friday afternoon please?"),
                       .notice(text: "No suggestion: the result only repeated text on screen.", reason: "copies-context"))
    }

    func testAbstainedAndRejectedOutputKeepTheirReasonAndSpeakToTheMode() throws {
        let marker = SuggestionPrompt.abstainMarker
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "notes", location: 0, length: 5))
        XCTAssertEqual(decide(.output(marker), mode: .draft, draft: draft),
                       .notice(text: "No suggestion for this selection.", reason: "model-abstained"))
        XCTAssertEqual(decide(.output(marker), mode: .continuation, draft: draft),
                       .notice(text: "No suggestion: nothing to add from your text and this context.", reason: "model-abstained"))
        XCTAssertEqual(decide(.output("one\ntwo"), mode: .reply, draft: try blank(), singleLine: true),
                       .notice(text: "No suggestion from this context.", reason: "multiline-single-line-field"))
    }

    func testModelFailuresAreNoticesAndCancellationDismisses() throws {
        let draft = try blank()
        XCTAssertEqual(decide(.unavailable("not ready"), mode: .reply, draft: draft),
                       .notice(text: "No suggestion: the model is unavailable.", reason: "model-unavailable"))
        XCTAssertEqual(decide(.timedOut, mode: .reply, draft: draft),
                       .notice(text: "No suggestion: the model took too long.", reason: "timed-out"))
        XCTAssertEqual(decide(.blocked, mode: .reply, draft: draft),
                       .notice(text: "No suggestion: the previous request is still ending.", reason: "blocked"))
        XCTAssertEqual(decide(.failed, mode: .reply, draft: draft),
                       .notice(text: "No suggestion: the model could not complete the request.", reason: "model-failed"))
        XCTAssertEqual(decide(.cancelled, mode: .reply, draft: draft), .dismiss)
    }

    func testOnlyRepliesAndContinuationsNeedOutsideContext() {
        XCTAssertEqual(SuggestionPresentation.missingContext(for: .reply),
                       .notice(text: SuggestionPresentation.needsNotes, reason: "no-context"))
        XCTAssertEqual(SuggestionPresentation.missingContext(for: .continuation),
                       .notice(text: "No suggestion: Jot has nothing from the last few minutes to continue from.", reason: "no-context"))
        XCTAssertNil(SuggestionPresentation.missingContext(for: .draft))
    }
}
