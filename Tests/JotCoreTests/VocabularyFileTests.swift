import XCTest
@testable import JotCore

final class VocabularyFileTests: XCTestCase {
    /// The sample docs/SHARED-CONTRACT.md points Jot for Android at; both apps read the same file.
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/contract/vocabulary-v1.json")
    private let sample = [VocabularyFile.Entry(preferred: "SwiftUI"), .init(preferred: "C++", heard: "see plus plus"),
                          .init(preferred: "Monroe", heard: "mon row", enabled: false)]

    private func refusal(_ json: String) -> String? {
        do { _ = try VocabularyFile.decode(Data(json.utf8)); return nil } catch { return error.localizedDescription }
    }

    func testTheSharedSampleReadsAsTheListItWasMadeFromAndExportWritesTheSameFile() throws {
        let data = try Data(contentsOf: fixture)
        XCTAssertEqual(try VocabularyFile.decode(data), sample)
        let entries = sample.map { VocabularyEntry(preferred: $0.preferred, heard: $0.heard, enabled: $0.enabled) }
        let exported = try VocabularyFile.encode(entries)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: exported) as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(entries[0].id.uuidString), "ids stay on this Mac")
        XCTAssertEqual(exported.last, UInt8(ascii: "\n"))
    }

    func testAHandWrittenFileMayLeaveOutHeardEnabledAndFieldsALaterVersionAdds() throws {
        let entries = try VocabularyFile.decode(Data(#"{"format": "jot.vocabulary", "version": 1, "note": "from my phone", "entries": [{"preferred": "Jot", "source": "android"}]}"#.utf8))
        XCTAssertEqual(entries, [.init(preferred: "Jot", heard: "", enabled: true)])
    }

    func testRefusesOtherFilesNewerVersionsAndBrokenEntries() {
        XCTAssertEqual(refusal("[]"), "That file is not a Jot vocabulary export.")
        XCTAssertEqual(refusal(#"{"format": "jot.settings", "version": 1, "entries": []}"#), "That file is not a Jot vocabulary export.")
        XCTAssertEqual(refusal(#"{"format": "jot.vocabulary", "entries": []}"#), "That file is not a Jot vocabulary export.")
        XCTAssertEqual(refusal(#"{"format": "jot.vocabulary", "version": 2, "entries": []}"#),
                       "That file uses vocabulary version 2, which this Jot cannot read. Update Jot to import it.")
        XCTAssertEqual(refusal(#"{"format": "jot.vocabulary", "version": 1, "entries": [{"heard": "jot"}]}"#), "The entries in that file could not be read.")
        XCTAssertEqual(refusal(#"{"format": "jot.vocabulary", "version": 1, "entries": [{"preferred": "Jot", "enabled": "yes"}]}"#), "The entries in that file could not be read.")
        XCTAssertNotNil(refusal(String(repeating: " ", count: VocabularyFile.maximumBytes + 1)))
    }

    func testImportAddsOnlyNewPhrasesAndNeverChangesAnEntryTheListHas() throws {
        var vocabulary = PersonalVocabulary()
        let kept = VocabularyEntry(preferred: "Monroe", heard: "Mon  Row", enabled: true)
        try vocabulary.save(kept)
        try vocabulary.save(VocabularyEntry(preferred: "SwiftUI"))
        let file = sample + [.init(preferred: "  Kotlin  ", heard: " cot lin "), .init(preferred: "Cotlin", heard: "COT LIN")]
        let plan = try VocabularyFile.additions(file, to: vocabulary)
        XCTAssertEqual(plan.added, [.init(preferred: "C++", heard: "see plus plus"), .init(preferred: "Kotlin", heard: "cot lin")])
        XCTAssertEqual(plan.skipped, 3, "SwiftUI and mon row are in the list; the second cot lin repeats the file's first")
    }

    func testImportChecksEveryEntryAndTheLimitBeforeAnythingIsSaved() throws {
        XCTAssertThrowsError(try VocabularyFile.additions([.init(preferred: "Jot"), .init(preferred: " ")], to: .init())) { error in
            XCTAssertEqual(error.localizedDescription, "Entry 2: Enter a preferred spelling. Nothing was imported.")
        }
        XCTAssertThrowsError(try VocabularyFile.additions([.init(preferred: "Jot", heard: "line\nbreak")], to: .init()))
        var full = PersonalVocabulary()
        for index in 0..<VocabularyRequest.maximumEntries { try full.save(VocabularyEntry(preferred: "word\(index)")) }
        XCTAssertEqual(try VocabularyFile.additions([.init(preferred: "word0")], to: full).skipped, 1)
        XCTAssertThrowsError(try VocabularyFile.additions([.init(preferred: "new")], to: full))
    }
}
