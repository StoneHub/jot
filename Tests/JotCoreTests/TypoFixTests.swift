import XCTest
@testable import JotCore

final class TypoFixTests: XCTestCase {
    // MARK: Review

    func testAcceptsHeavyTyposAndKeepsTheUsersWording() {
        let source = "i thnik teh meeting is tomorow but im nto sure"
        let output = "I think the meeting is tomorrow but I'm not sure"
        XCTAssertEqual(TypoFixReview.review(output, source: source), .fixed(text: output, changes: 3))
    }

    func testAcceptsWordsRunTogetherOrSplitApart() {
        let source = "ti hsoul dbe fine, dont worry abuot it"
        let output = "It should be fine, don't worry about it"
        XCTAssertEqual(TypoFixReview.review(output, source: source), .fixed(text: output, changes: 3))
    }

    func testRejectsRewritesSynonymsAndAddedWords() {
        XCTAssertEqual(TypoFixReview.review("This is a huge deal", source: "thsi is a big deal"), .rejected(reason: "rewrite"))
        XCTAssertEqual(TypoFixReview.review("I do not want to go", source: "I want to go"), .rejected(reason: "rewrite"))
        XCTAssertEqual(TypoFixReview.review("Could you please send me the report by 5 PM?", source: "can you sned me the reprot by 5pm"),
                       .rejected(reason: "numbers"))
    }

    func testRejectsAFixThatReversesTheMeaning() {
        XCTAssertEqual(TypoFixReview.review("I disagree with you", source: "I aggree with you"), .rejected(reason: "negation"))
        XCTAssertEqual(TypoFixReview.review("That is impossible", source: "That is possible"), .rejected(reason: "negation"))
        XCTAssertEqual(TypoFixReview.review("I am not going", source: "I am nto going"), .fixed(text: "I am not going", changes: 1))
        XCTAssertEqual(TypoFixReview.review("The information is here", source: "The nformation is here"),
                       .fixed(text: "The information is here", changes: 1), "A dropped first i is a typo, not a prefix")
    }

    func testKeepsTheUsersSpacingAndLineBreaksOutsideFixes() {
        let source = "  first linee\n\n    indented  wrod\n"
        XCTAssertEqual(TypoFixReview.review("first line indented word", source: source), .rejected(reason: "line-breaks"),
                       "Joined lines are a rewrite")
        XCTAssertEqual(TypoFixReview.review("first line\n\n indented word\n", source: source),
                       .fixed(text: "  first line\n\n    indented  word\n", changes: 2))
    }

    func testSpacingAloneAndIdenticalTextAreUnchanged() {
        XCTAssertEqual(TypoFixReview.review("All good here", source: "All good here"), .unchanged)
        XCTAssertEqual(TypoFixReview.review("All good  here", source: "All good here"), .unchanged)
    }

    func testStripsTheWrapperQuotesAndALabelLine() {
        XCTAssertEqual(TypoFixReview.review("<text>\nsee you soon\n</text>", source: "see yuo soon"), .fixed(text: "see you soon", changes: 1))
        XCTAssertEqual(TypoFixReview.review("\u{201C}see you soon\u{201D}", source: "see yuo soon"), .fixed(text: "see you soon", changes: 1))
        XCTAssertEqual(TypoFixReview.review("Corrected text:\nsee you soon", source: "see yuo soon"), .fixed(text: "see you soon", changes: 1))
        XCTAssertEqual(TypoFixReview.review("   ", source: "see yuo soon"), .rejected(reason: "empty"))
    }

    func testRemovesADoubledWordWithItsSpace() {
        XCTAssertEqual(TypoFixReview.review("see you at the office", source: "see you at the the office"),
                       .fixed(text: "see you at the office", changes: 1))
    }

    // MARK: Edit

    func testEditCoversOnlyTheChangedStretchInUTF16() throws {
        let edit = try XCTUnwrap(TypoFixEdit(source: "👋 teh cat and teh dog", corrected: "👋 the cat and the dog", offset: 5))
        XCTAssertEqual(edit.location, 5 + 4, "The emoji is two UTF-16 units, then a space and the shared t")
        XCTAssertEqual(edit.original, "eh cat and teh")
        XCTAssertEqual(edit.replacement, "he cat and the")
        XCTAssertNil(TypoFixEdit(source: "same", corrected: "same"))
    }

    func testEditSidesAreNeverEmptySoBothDirectionsInsert() throws {
        let removal = try XCTUnwrap(TypoFixEdit(source: "thhe", corrected: "the"))
        XCTAssertFalse(removal.replacement.isEmpty)
        XCTAssertEqual(removal.applied(to: "thhe"), "the")
        let addition = try XCTUnwrap(TypoFixEdit(source: "dont", corrected: "don't"))
        XCTAssertFalse(addition.original.isEmpty)
        XCTAssertEqual(addition.applied(to: "dont"), "don't")
        XCTAssertEqual(addition.reversed.applied(to: "don't"), "dont")
    }

    func testEditAppliesOnlyWhereTheFieldStillHoldsTheOriginal() throws {
        let edit = try XCTUnwrap(TypoFixEdit(source: "teh end", corrected: "the end", offset: 6))
        XCTAssertEqual(edit.applied(to: "Notes teh end"), "Notes the end")
        XCTAssertNil(edit.applied(to: "Notes the end"))
        XCTAssertEqual(edit.seed.location, 7)
        XCTAssertEqual(edit.seed.text, "eh")
    }

    // MARK: Distance

    func testDistanceCountsASwapAsOneEdit() {
        XCTAssertEqual(TextDistance.optimalStringAlignment(Array("teh"), Array("the"), limit: 5), 1)
        XCTAssertEqual(TextDistance.optimalStringAlignment(Array("kitten"), Array("sitting"), limit: 5), 3)
        XCTAssertEqual(TextDistance.optimalStringAlignment(Array("a"), Array("abcdef"), limit: 2), 3, "Capped at limit + 1")
        XCTAssertEqual(TextDistance.optimalStringAlignment(Array(""), Array("ab"), limit: 5), 2)
    }

    // MARK: Prompt

    func testPromptBoundsGrowWithTheText() {
        let short = TypoFixPrompt.request(for: "teh")
        XCTAssertTrue(short.prompt.contains("teh"))
        XCTAssertEqual(short.maximumResponseTokens, 65)
        XCTAssertEqual(TypoFixPrompt.maximumResponseTokens(for: String(repeating: "a", count: 10_000)), 2_000)
        XCTAssertEqual(TypoFixPrompt.deadline(for: "teh"), .seconds(4))
        XCTAssertEqual(TypoFixPrompt.deadline(for: String(repeating: "a", count: 3_000)), .seconds(29))
    }

    // MARK: Shortcut

    func testKeyRequestsOnceAndConsumesItsKeyUp() {
        var tracker = TypoFixKeyTracker()
        let shortcut = TypoFixShortcutPreferences.standard
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [.control, .option], repeating: false, shortcut: shortcut),
                       .init(consume: true, request: true))
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [.control, .option], repeating: true, shortcut: shortcut),
                       .init(consume: true, request: false))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], repeating: false, shortcut: shortcut), .init(consume: true))
        XCTAssertEqual(tracker.handle(.keyUp, keyCode: 49, modifiers: [], repeating: false, shortcut: shortcut), .init())
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [.control], repeating: false, shortcut: shortcut), .init())
        XCTAssertEqual(tracker.handle(.keyDown, keyCode: 49, modifiers: [.control, .option], repeating: false, shortcut: nil), .init())
    }

    func testShortcutDefaultsToControlOptionSpaceAndAvoidsOtherShortcuts() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "jot-typo-fix-" + UUID().uuidString))
        let preferences = TypoFixShortcutPreferences(defaults: defaults)
        XCTAssertEqual(preferences.load(), TypoFixShortcutPreferences.standard)
        XCTAssertEqual(preferences.load().displayName, "⌃⌥Space")
        let other = DictationShortcut(keyCode: 3, modifiers: [.control, .option], keyLabel: "F")
        XCTAssertThrowsError(try preferences.save(other, others: [.fn, other]))
        try preferences.save(other, others: [.fn, nil])
        XCTAssertEqual(preferences.load(), other)
        try preferences.save(TypoFixShortcutPreferences.standard, others: [.fn])
        XCTAssertNil(defaults.object(forKey: JotDefaultsKey.typoFixShortcut), "The default is not stored")
        XCTAssertNil(TypoFixShortcutPreferences.effective(other, others: [other]))
        XCTAssertEqual(TypoFixShortcutPreferences.effective(other, others: [.fn, nil]), other)
    }

    func testCountersNameEveryOutcome() {
        XCTAssertEqual(UsageCounter.typoFixRequested.name, "typoFix.requested")
        XCTAssertEqual(UsageCounter.typoFix(.selectionUnavailable).name, "typoFix.outcome.selectionUnavailable")
        XCTAssertEqual(UsageCounter.allCases.filter { $0.name.hasPrefix("typoFix.") }.count, TypoFixOutcome.allCases.count + 1)
    }
}
