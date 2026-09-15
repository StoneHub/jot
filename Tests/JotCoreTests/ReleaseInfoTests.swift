import XCTest
@testable import JotCore
final class ReleaseInfoTests: XCTestCase {
    func testSemanticVersionOrdersNumerically() {
        let a = SemanticVersion.parse("0.1.0")!, b = SemanticVersion.parse("0.1.10")!, c = SemanticVersion.parse("0.2.0")!
        XCTAssertLessThan(a, b); XCTAssertLessThan(b, c); XCTAssertLessThan(a, c)
        XCTAssertEqual(SemanticVersion.parse("v1.2.3"), SemanticVersion.parse("1.2.3"))
        XCTAssertEqual(SemanticVersion.parse("1.2"), SemanticVersion.parse("1.2.0"))
        XCTAssertEqual(SemanticVersion.parse("1.2.3")?.description, "1.2.3")
        XCTAssertNil(SemanticVersion.parse("junk")); XCTAssertNil(SemanticVersion.parse("1.2.x")); XCTAssertNil(SemanticVersion.parse(""))
        XCTAssertNil(SemanticVersion.parse("1..2")); XCTAssertNil(SemanticVersion.parse("v"))
    }
    // Field names follow https://docs.github.com/en/rest/releases/releases#get-the-latest-release.
    private let payload = """
    {"url": "https://api.github.com/repos/octocat/Hello-World/releases/1", "html_url": "https://github.com/octocat/Hello-World/releases/v0.1.1",
     "id": 1, "tag_name": "v0.1.1", "target_commitish": "main", "name": "Jot 0.1.1", "draft": false, "prerelease": false,
     "created_at": "2026-09-15T00:00:00Z", "published_at": "2026-09-15T00:00:00Z",
     "body": "\\nFixes the thing.\\n\\nMore detail below.",
     "assets": [
       {"name": "Jot-0.1.1.zip.sha256", "browser_download_url": "https://github.com/octocat/Hello-World/releases/download/v0.1.1/Jot-0.1.1.zip.sha256", "size": 64, "content_type": "text/plain", "download_count": 0, "state": "uploaded"},
       {"name": "Jot-0.1.1.zip", "browser_download_url": "https://github.com/octocat/Hello-World/releases/download/v0.1.1/Jot-0.1.1.zip", "size": 1024000, "content_type": "application/zip", "download_count": 150, "state": "uploaded"}
     ]}
    """
    func testDecodesLatestReleaseAndPicksNamedAsset() throws {
        let release = try ReleaseInfo.latest(from: Data(payload.utf8)) { "Jot-\($0).zip" }
        XCTAssertEqual(release.version, SemanticVersion.parse("0.1.1"))
        XCTAssertEqual(release.tag, "v0.1.1")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/octocat/Hello-World/releases/v0.1.1")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "Jot-0.1.1.zip")
        XCTAssertEqual(release.assetSize, 1_024_000)
        XCTAssertEqual(release.firstNoteLine, "Fixes the thing.")
        XCTAssertTrue(release.version > SemanticVersion.parse("0.1.0")!)
    }
    func testRejectsMissingAssetBadTagAndJunk() {
        XCTAssertThrowsError(try ReleaseInfo.latest(from: Data(payload.utf8)) { _ in "Other.zip" }) { XCTAssertEqual($0 as? ReleaseInfo.ParseError, .noAsset("Other.zip")) }
        let badTag = payload.replacingOccurrences(of: "\"tag_name\": \"v0.1.1\"", with: "\"tag_name\": \"nightly\"")
        XCTAssertThrowsError(try ReleaseInfo.latest(from: Data(badTag.utf8)) { "Jot-\($0).zip" }) { XCTAssertEqual($0 as? ReleaseInfo.ParseError, .badTag("nightly")) }
        XCTAssertThrowsError(try ReleaseInfo.latest(from: Data("not json".utf8)) { "Jot-\($0).zip" }) { XCTAssertEqual($0 as? ReleaseInfo.ParseError, .badJSON) }
        let noBody = payload.replacingOccurrences(of: "\"body\": \"\\nFixes the thing.\\n\\nMore detail below.\"", with: "\"body\": null")
        XCTAssertEqual(try ReleaseInfo.latest(from: Data(noBody.utf8)) { "Jot-\($0).zip" }.firstNoteLine, "")
    }
}
