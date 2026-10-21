import XCTest
@testable import JotCore

final class VocabularyRequestTests: XCTestCase {
    private func decode(_ json: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) }
    private func refusal(_ json: String, in vocabulary: PersonalVocabulary = .init()) throws -> String? {
        let params = try decode(json)
        do { _ = try VocabularyRequest.entry(params, in: vocabulary); return nil } catch { return error.localizedDescription }
    }

    func testAddsANewEntryEnabledByDefault() throws {
        let entry = try VocabularyRequest.entry(decode(#"{"preferred": "C++", "heard": "see plus plus"}"#), in: .init())
        XCTAssertEqual(entry.preferred, "C++"); XCTAssertEqual(entry.heard, "see plus plus"); XCTAssertTrue(entry.enabled)
        var vocabulary = PersonalVocabulary()
        try vocabulary.save(entry)
        XCTAssertEqual(vocabulary.applying(to: "I write see plus plus"), "I write C++")
    }

    func testEditingByIdKeepsFieldsLeftOut() throws {
        var vocabulary = PersonalVocabulary()
        let saved = VocabularyEntry(preferred: "Monroe", heard: "mon row")
        try vocabulary.save(saved)
        let edited = try VocabularyRequest.entry(decode(#"{"id": "\#(saved.id.uuidString)", "enabled": false}"#), in: vocabulary)
        XCTAssertEqual(edited, VocabularyEntry(id: saved.id, preferred: "Monroe", heard: "mon row", enabled: false))
        let lowercased = try VocabularyRequest.entry(decode(#"{"id": "\#(saved.id.uuidString.lowercased())", "heard": ""}"#), in: vocabulary)
        XCTAssertEqual(lowercased.id, saved.id); XCTAssertEqual(lowercased.heard, "")
        XCTAssertEqual(try VocabularyRequest.id(decode(#"{"id": "\#(saved.id.uuidString)"}"#), in: vocabulary), saved.id)
    }

    func testRefusesUnknownIdsWrongTypesAndMissingSpelling() throws {
        XCTAssertEqual(try refusal(#"{"heard": "jot"}"#), "Enter a preferred spelling.")
        XCTAssertEqual(try refusal(#"{"id": "not-a-uuid"}"#), "No vocabulary entry has id not-a-uuid.")
        XCTAssertEqual(try refusal(#"{"id": "8B0F2C1E-6B1A-4C55-9E3B-1C1F4A7E2D10", "preferred": "Jot"}"#), "No vocabulary entry has id 8B0F2C1E-6B1A-4C55-9E3B-1C1F4A7E2D10.")
        XCTAssertEqual(try refusal(#"{"preferred": 5}"#), "preferred must be a string.")
        XCTAssertEqual(try refusal(#"{"preferred": "Jot", "enabled": 1}"#), "enabled must be true or false.")
        XCTAssertThrowsError(try VocabularyRequest.id([:], in: .init()))
    }

    func testNewEntriesStopAtTheLimit() throws {
        var vocabulary = PersonalVocabulary()
        for index in 0..<VocabularyRequest.maximumEntries { try vocabulary.save(VocabularyEntry(preferred: "word\(index)")) }
        XCTAssertEqual(try refusal(#"{"preferred": "one more"}"#, in: vocabulary), "Vocabulary holds at most \(VocabularyRequest.maximumEntries) entries.")
        let first = try XCTUnwrap(vocabulary.entries.first)
        XCTAssertNoThrow(try VocabularyRequest.entry(decode(#"{"id": "\#(first.id.uuidString)", "enabled": false}"#), in: vocabulary), "Edits still work at the limit")
    }
}
