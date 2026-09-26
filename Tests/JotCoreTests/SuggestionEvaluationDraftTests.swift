import CoreGraphics
import XCTest
@testable import JotCore

/// Brain-dump drafting, blank-field abstention and on-screen context (#90). Synthetic text only.
final class SuggestionEvaluationDraftTests: XCTestCase {
    private let notes = "reply to alex — can help saturday after 2, ask what tools to bring, keep it casual"

    func testNotesBecomeTheSeedWithoutAnyTranscript() throws {
        let caret = try XCTUnwrap(SuggestionDraftSnapshot(value: notes, location: (notes as NSString).length, length: 0))
        let whole = SuggestionSeed(text: notes, location: 0, length: (notes as NSString).length, isSelection: false)
        XCTAssertEqual(SuggestionPlan.make(draft: caret, role: "AXTextArea", hasAssociatedContext: false), .draft(whole))
        XCTAssertEqual(SuggestionPlan.make(draft: caret, role: "AXTextField", hasAssociatedContext: false), .draft(whole),
                       "Any editable field can turn notes into a draft")
        XCTAssertEqual(caret.text(around: whole).before, ""); XCTAssertEqual(caret.text(around: whole).after, "")
    }

    func testSelectionIsTheSeedAndTheRestOfTheFieldIsKept() throws {
        let value = "Hi team,\nfri standup moved 10am, bring demo\nThanks"
        let range = (value as NSString).range(of: "fri standup moved 10am, bring demo")
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: value, location: range.location, length: range.length))
        guard case .draft(let seed) = SuggestionPlan.make(draft: draft, role: "AXTextArea", hasAssociatedContext: false) else {
            return XCTFail("A selection with text is a seed")
        }
        XCTAssertEqual(seed, SuggestionSeed(text: "fri standup moved 10am, bring demo", location: range.location,
                                            length: range.length, isSelection: true))
        XCTAssertEqual(draft.text(around: seed).before, "Hi team,\n")
        XCTAssertEqual(draft.text(around: seed).after, "\nThanks")

        let spaces = try XCTUnwrap(SuggestionDraftSnapshot(value: "draft this  ", location: 10, length: 2))
        XCTAssertEqual(SuggestionPlan.make(draft: spaces, role: "AXTextArea", hasAssociatedContext: false),
                       .draft(SuggestionSeed(text: "draft this  ", location: 0, length: 12, isSelection: false)),
                       "A whitespace-only selection falls back to the whole draft")
    }

    func testBlankFieldAsksForNotesUnlessAComposerHasAssociatedContext() throws {
        for value in ["", "  \n", "\u{200B}", "\u{00A0}"] {
            let blank = try XCTUnwrap(SuggestionDraftSnapshot(value: value, location: 0, length: 0))
            XCTAssertTrue(blank.isBlank)
            XCTAssertEqual(SuggestionPlan.make(draft: blank, role: "AXTextArea", hasAssociatedContext: false), .needsNotes)
            XCTAssertEqual(SuggestionPlan.make(draft: blank, role: "AXTextArea", hasAssociatedContext: true), .reply)
            XCTAssertEqual(SuggestionPlan.make(draft: blank, role: "AXTextField", hasAssociatedContext: true), .needsNotes,
                           "Search and URL fields don't establish that they want a reply")
        }
    }

    func testDrawnHintCountsOnlyWhenItIsTheWholeValue() {
        XCTAssertTrue(FieldHint.isHintClass(["placeholder"]))
        XCTAssertTrue(FieldHint.isHintClass(["is-empty", "is-editor-empty"]))
        XCTAssertTrue(FieldHint.isHintClass(["composer-Placeholder"]))
        XCTAssertFalse(FieldHint.isHintClass(["ProseMirror-trailingBreak", "empty-state-card"]))
        XCTAssertTrue(FieldHint.valueIsHint("Ask Codex anything\n", hints: ["Ask Codex anything"]))
        XCTAssertTrue(FieldHint.valueIsHint("Ask Codex anything. @ to add files", hints: ["Ask Codex anything.", "@ to add files"]))
        XCTAssertFalse(FieldHint.valueIsHint("Ask Codex anything about exports", hints: ["Ask Codex anything"]),
                       "Typed words that start like the hint stay user text")
        XCTAssertFalse(FieldHint.valueIsHint("Ask Codex anything", hints: []))
        XCTAssertFalse(FieldHint.valueIsHint("", hints: ["Ask Codex anything"]))
    }

    func testDraftPromptQuotesTheNotesAndKeepsSurroundingText() {
        let target = Target(app: "Slack", mode: .draft, purpose: "text-entry", before: "", after: "",
                            requestedAt: "2026-09-26T12:00:00Z", seed: notes, window: "Weekend plans")
        let request = SuggestionPrompt.request(for: ScenarioInput(target: target, sources: []), sources: [])
        let lines = request.prompt.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, #"Field: draft for a text-entry field in Slack, window "Weekend plans"."#)
        XCTAssertTrue(lines.contains("Notes to rewrite: " + SuggestionPrompt.quoted(notes)))
        XCTAssertFalse(request.prompt.contains("Sources"), "Seed-only drafting needs no sources")
        XCTAssertFalse(request.prompt.contains("kept as is"))
        XCTAssertEqual(lines.last, "Return the finished text that replaces the notes, or NO_SUGGESTION.")
        XCTAssertTrue(request.instructions.contains("Keep every name, number, date, time and constraint"))
        XCTAssertEqual(request.maximumResponseTokens, 137, "82 UTF-16 units of notes: 82 / 2 + 96")

        var selection = target
        selection.before = "Hi team,\n"; selection.after = "\nThanks"; selection.seed = String(repeating: "note ", count: 200)
        let selected = SuggestionPrompt.request(for: ScenarioInput(target: selection, sources: []), sources: [])
        XCTAssertTrue(selected.prompt.contains(#"Field text before the notes, kept as is: "Hi team,\n""#))
        XCTAssertTrue(selected.prompt.contains(#"Field text after the notes, kept as is: "\nThanks""#))
        XCTAssertEqual(selected.maximumResponseTokens, 400, "Long notes get a larger, bounded budget")
    }

    func testReplyAndDraftDescribeScreenTextWithoutAnAuthor() {
        let screen = ScreenContext.source("Rowan: can anyone help me move a couch saturday?", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(screen.kind, "screen-text"); XCTAssertEqual(screen.role, "unknown")
        let target = Target(app: "Slack", mode: .reply, purpose: "text-entry", before: "", after: "", requestedAt: "now")
        var input = ScenarioInput(target: target, sources: [screen])
        input.association = .explicitRecentRequest
        let selection = SourceSelector.select(input)
        XCTAssertEqual(selection.selected, [screen])
        let prompt = SuggestionPrompt.request(for: input, sources: selection.selected).prompt
        XCTAssertTrue(prompt.contains("1. 1970-01-01T00:00:00Z, visible text above the field in this window, newest last; authors are not identified"))
        XCTAssertTrue(prompt.contains(SuggestionPrompt.quoted(screen.text)))
        XCTAssertTrue(prompt.contains("If the visible text holds no message for the user to answer or continue, return NO_SUGGESTION."),
                      "A new chat's greeting is not something to reply to")
        let withoutScreen = SuggestionPrompt.request(for: ScenarioInput(target: target, sources: []), sources: []).prompt
        XCTAssertFalse(withoutScreen.contains("visible text"), "Prompts without screen text keep the v3 wording")
    }

    func testDraftOutputKeepsParagraphsAndDropsEchoedLabels() {
        XCTAssertEqual(SuggestionOutput.process("Hey Alex,\n\nI can help Saturday after 2.", mode: .draft),
                       .suggestion("Hey Alex,\n\nI can help Saturday after 2."))
        XCTAssertEqual(SuggestionOutput.process("Finished text: Hey Alex, I can help.", mode: .draft), .suggestion("Hey Alex, I can help."))
        XCTAssertEqual(SuggestionOutput.process("\u{201C}Hey Alex\u{201D}", mode: .draft), .suggestion("Hey Alex"))
        XCTAssertEqual(SuggestionOutput.process("NO_SUGGESTION", mode: .draft), .abstained("model-abstained"))
        XCTAssertEqual(SuggestionOutput.process("Hey\nAlex", mode: .draft, singleLine: true), .rejected("multiline-single-line-field"))
        XCTAssertEqual(SuggestionOutput.process("a\n\nb", mode: .reply), .rejected("multiple-paragraphs"), "Other modes are unchanged")
    }

    func testReviewRejectsUnchangedNotesHintRewordingAndCopiedQuestions() throws {
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: notes, location: 0, length: 0))
        XCTAssertEqual(SuggestionOutput.review(notes.uppercased(), draft: draft, seed: notes, placeholder: nil, context: nil), .unchanged)
        XCTAssertEqual(SuggestionOutput.review("Hey Alex, I can help Saturday after 2. What tools should I bring?", draft: draft,
                                               seed: notes, placeholder: nil, context: nil), .accept)

        let blank = try XCTUnwrap(SuggestionDraftSnapshot(value: "", location: 0, length: 0))
        XCTAssertEqual(SuggestionOutput.review("Ask Codex anything", draft: blank, seed: nil, placeholder: "Ask Codex anything",
                                               context: nil), .restatesHint)
        XCTAssertEqual(SuggestionOutput.review("Ask Codex anything you want to know", draft: blank, seed: nil,
                                               placeholder: "Ask Codex anything", context: nil), .restatesHint)
        XCTAssertEqual(SuggestionOutput.review("Ask Codex to add a test for the export pause", draft: blank, seed: nil,
                                               placeholder: "Ask Codex anything", context: nil), .accept)

        let screen = "Should I also update the snapshot tests for the exporter?"
        XCTAssertEqual(SuggestionOutput.review("Should I also update the snapshot tests for the exporter?", draft: blank, seed: nil,
                                               placeholder: nil, context: "Codex\n\n" + screen), .copiesContext)
        XCTAssertEqual(SuggestionOutput.review("Yes, update the snapshot tests too.", draft: blank, seed: nil,
                                               placeholder: nil, context: screen), .accept)
    }

    func testScreenExcerptKeepsTheFieldColumnAboveTheFieldNewestLast() {
        let field = CGRect(x: 300, y: 800, width: 600, height: 60)
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let items = [
            ScreenText("I added", frame: CGRect(x: 320, y: 500, width: 60, height: 20)),
            ScreenText("Other chat preview", frame: CGRect(x: 20, y: 300, width: 180, height: 20)),
            ScreenText("the test.", frame: CGRect(x: 382, y: 500, width: 60, height: 20)),
            ScreenText("Fix export pause", frame: CGRect(x: 500, y: 40, width: 200, height: 20)),
            ScreenText("Send", frame: CGRect(x: 850, y: 870, width: 40, height: 20)),
            ScreenText("Old message", frame: CGRect(x: 320, y: -200, width: 280, height: 20)),
            ScreenText("  Can   you add a test?", frame: CGRect(x: 320, y: 400, width: 280, height: 20)),
            ScreenText("Run it", frame: CGRect(x: 320, y: 523, width: 280, height: 20)),
        ]
        XCTAssertEqual(ScreenContext.excerpt(items, field: field, visible: visible),
                       "Fix export pause\n\nCan you add a test?\n\nI added the test.\nRun it",
                       "Sidebar, below-field and scrolled-away text is excluded; runs on one line are joined")
        XCTAssertEqual(ScreenContext.excerpt(items, field: field, visible: visible, maximumBytes: 30), "I added the test.\nRun it",
                       "The bound keeps the lines nearest the field")
        let tail = ScreenContext.excerpt([items[6]], field: field, visible: visible, maximumBytes: 8)
        XCTAssertEqual(tail, " a test?", "An over-long line keeps its end, nearest the field")
        XCTAssertNil(ScreenContext.excerpt([items[1], items[4]], field: field, visible: visible))
    }

    func testAttributionNamesWhoseWordsWereUsed() {
        let screen = ScreenContext.source("x", at: Date())
        let dictation = Source(id: "d", kind: "dictation", role: "user", origin: "jot", scope: .init(), timestamp: "t",
                               revision: 1, status: .current, text: "y")
        let whole = SuggestionPlan.draft(SuggestionSeed(text: "a", location: 0, length: 1, isSelection: false))
        let selected = SuggestionPlan.draft(SuggestionSeed(text: "a", location: 0, length: 1, isSelection: true))
        XCTAssertEqual(SuggestionAttribution.line(plan: whole, selected: [screen], sessionTitle: nil), "Your notes + text on screen")
        XCTAssertEqual(SuggestionAttribution.line(plan: selected, selected: [], sessionTitle: nil), "Your selection")
        XCTAssertEqual(SuggestionAttribution.line(plan: .reply, selected: [screen, dictation], sessionTitle: nil),
                       "Text on screen + recent dictation")
    }

    @MainActor func testPerCallDeadlineOverridesTheGateDeadline() async {
        let gate = ModelCallGate(deadline: .seconds(10))
        let request = ModelRequest(instructions: "test", prompt: "test", maximumResponseTokens: 1)
        let result = await gate.call(request, deadline: .milliseconds(50)) { _ in
            try await Task.sleep(for: .seconds(2)); return "late"
        }
        XCTAssertEqual(result, .timedOut)
        let settled = await gate.settle(within: .seconds(3))
        XCTAssertTrue(settled)
    }
}
