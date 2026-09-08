import XCTest
@testable import JotCore

final class PersonalVocabularyTests: XCTestCase {
    func testWholeWordsUnicodePunctuationAndCapitalization() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(.init(preferred: "Jot"))
        try vocabulary.save(.init(preferred: "Monroe", heard: "mon row"))
        XCTAssertEqual(vocabulary.applying(to: "👋 JOT, mon  row! jotting jot_2 éjot joté jot's."),
                       "👋 Jot, Monroe! jotting jot_2 éjot joté Jot's.")
        try vocabulary.save(.init(preferred: "C++", heard: "see plus plus"))
        XCTAssertEqual(vocabulary.applying(to: "Use see plus plus."), "Use C++.")
    }

    func testLongestPhraseWinsWithoutCascadingOrTemplateExpansion() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(.init(preferred: "swift", heard: "quick"))
        try vocabulary.save(.init(preferred: "SwiftUI", heard: "swift you eye"))
        try vocabulary.save(.init(preferred: "replacement", heard: "swift"))
        try vocabulary.save(.init(preferred: "$1\\folder", heard: "dollar"))
        XCTAssertEqual(vocabulary.applying(to: "quick swift you eye dollar"), "swift SwiftUI $1\\folder")
        try vocabulary.save(.init(preferred: "dot", heard: "a.b"))
        XCTAssertEqual(vocabulary.applying(to: "a.b axb"), "dot axb")
    }

    func testDisableEditRemoveAndSnapshot() throws {
        var vocabulary = PersonalVocabulary()
        var entry = VocabularyEntry(preferred: "Jot", heard: "jaw")
        try vocabulary.save(entry)
        let inFlight = vocabulary
        entry.enabled = false; try vocabulary.save(entry)
        XCTAssertEqual(vocabulary.applying(to: "jaw"), "jaw")
        XCTAssertEqual(inFlight.applying(to: "jaw"), "Jot")
        entry.enabled = true; entry.preferred = "JOT"; try vocabulary.save(entry)
        XCTAssertEqual(vocabulary.entries.count, 1)
        XCTAssertEqual(vocabulary.applying(to: "jaw"), "JOT")
        vocabulary.remove(entry.id)
        XCTAssertEqual(vocabulary.applying(to: "jaw"), "jaw")
    }

    func testValidationRejectsAmbiguousAndEmptyEntries() throws {
        var vocabulary = PersonalVocabulary()
        XCTAssertThrowsError(try vocabulary.save(.init(preferred: " \n")))
        XCTAssertThrowsError(try vocabulary.save(.init(preferred: "two\nlines")))
        XCTAssertThrowsError(try vocabulary.save(.init(preferred: String(repeating: "x", count: 201))))
        try vocabulary.save(.init(preferred: " Jot ", heard: " j ott "))
        XCTAssertEqual(vocabulary.entries.first?.preferred, "Jot")
        XCTAssertThrowsError(try vocabulary.save(.init(preferred: "Other", heard: "J  OTT")))
        XCTAssertEqual(vocabulary.entries.count, 1)
    }

    func testPreferencesPersistWithoutTouchingTranscriptPreferencesAndKeepBadData() throws {
        let suite = "jot-vocabulary-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "historyTextView")
        let preferences = VocabularyPreferences(defaults: defaults)
        XCTAssertTrue(try preferences.load().entries.isEmpty)
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(.init(preferred: "SwiftUI", heard: "swift you eye", enabled: false))
        try preferences.save(vocabulary)
        XCTAssertEqual(try VocabularyPreferences(defaults: defaults).load(), vocabulary)
        XCTAssertTrue(defaults.bool(forKey: "historyTextView"))
        let bad = Data("invalid".utf8)
        defaults.set(bad, forKey: "personalVocabulary")
        XCTAssertThrowsError(try preferences.load())
        XCTAssertEqual(defaults.data(forKey: "personalVocabulary"), bad)
    }
}
