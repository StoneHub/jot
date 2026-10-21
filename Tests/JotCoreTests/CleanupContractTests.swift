import XCTest
import JotCore

/// docs/contract/cleanup-checks-v1.json is the cleanup check corpus Jot for Mac and Jot for Android share; docs/SHARED-CONTRACT.md has the rules.
final class CleanupContractTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Case: Decodable { let name: String; let source: String; let candidate: String; let accept: Bool }
        let format: String
        let version: Int
        let cases: [Case]
    }

    func testCleanupValidationDecidesEverySharedCaseAsTheContractSays() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/contract/cleanup-checks-v1.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.format, "jot.cleanup-checks")
        XCTAssertEqual(corpus.version, 1)
        XCTAssertTrue(corpus.cases.contains { $0.accept } && corpus.cases.contains { !$0.accept })
        for item in corpus.cases {
            XCTAssertEqual(CleanupValidation.accepts(item.candidate, source: item.source), item.accept, item.name)
        }
    }
}
