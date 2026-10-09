import XCTest
import JotCore
@testable import JotCLI

final class SettingsImportTests: XCTestCase {
    func testImportSendsOneSetPerSettingOfTheNamedVariantFromAVariantsFileOrALabResult() throws {
        let file = Data(#"[{"name": "current", "settings": {}}, {"name": "steadier", "settings": {"paragraphPause": 2, "cleanUpTranscriptions": false}}]"#.utf8)
        let requests = try SettingsImport.requests(file, variant: "steadier")
        XCTAssertEqual(requests.map { $0["key"] as? String }, ["cleanUpTranscriptions", "paragraphPause"])
        XCTAssertEqual(requests.map { $0["value"] as? NSObject }, [false as NSObject, 2.0 as NSObject])

        // jot lab writes variants.json with rows and timings beside each name and its settings.
        let result = Data(#"[{"name": "lab pick", "settings": {"minimumSpeakerTurn": 1.5}, "recognitionRun": 1, "rows": [], "cleanupOutcomes": {}}]"#.utf8)
        XCTAssertEqual(try SettingsImport.requests(result, variant: "lab pick").map { $0["key"] as? String }, ["minimumSpeakerTurn"])
    }

    func testImportRefusesAMissingVariantAndOneThatChangesNothing() {
        let file = Data(#"[{"name": "current", "settings": {}}]"#.utf8)
        XCTAssertThrowsError(try SettingsImport.requests(file, variant: "other"))
        XCTAssertThrowsError(try SettingsImport.requests(file, variant: "current"))
    }
}
