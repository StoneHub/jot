import XCTest
@testable import JotCore
import Darwin
import os

final class LocalServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        // macOS Unix socket paths have a 104-byte capacity; NSTemporaryDirectory can be much longer.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("jot-ipc-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRoundTripPermissionsAndCompetingOwner() throws {
        let socketURL = directory.appendingPathComponent("service.sock")
        let server = LocalServiceServer(socketURL: socketURL) { data in
            let request = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try! JSONSerialization.data(withJSONObject: ["ok": true, "result": request])
        }
        try server.start(); defer { server.stop() }
        let response = try LocalServiceClient(socketURL: socketURL).request(method: "speech.status", params: ["sample": "hello"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let result = object["result"] as? [String: Any]
        XCTAssertEqual(result?["method"] as? String, "speech.status")
        let attrs = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let competing = LocalServiceServer(socketURL: socketURL) { $0 }
        XCTAssertThrowsError(try competing.start())
        competing.stop() // Must not remove the original service's socket.
        XCTAssertNoThrow(try LocalServiceClient(socketURL: socketURL).request(method: "speech.status"))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testRefusesNonSocketAndRejectsOversizedRequest() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("service.sock")
        try Data("keep me".utf8).write(to: socketURL)
        let server = LocalServiceServer(socketURL: socketURL) { $0 }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "keep me")
        XCTAssertThrowsError(try LocalServiceClient(socketURL: socketURL).request(method: "search", params: ["query": String(repeating: "x", count: 1_048_577)]))
    }

    func testLargeResponseIsRejectedWithoutBreakingService() throws {
        let socketURL = directory.appendingPathComponent("service.sock")
        let server = LocalServiceServer(socketURL: socketURL) { _ in Data(repeating: 120, count: 4_194_305) }
        try server.start(); defer { server.stop() }
        let response = try LocalServiceClient(socketURL: socketURL).request(method: "test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue((object["error"] as? String)?.contains("size limit") == true)
    }

    func testHelperPeerReachesOnlyControlMethods() throws {
        let socketURL = directory.appendingPathComponent("service.sock")
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let server = LocalServiceServer(socketURL: socketURL, isHelper: { path in
            seen.withLock { $0.append(path) }; return true
        }) { _ in Data(#"{"ok":true,"result":{}}"#.utf8) }
        try server.start(); defer { server.stop() }
        let client = LocalServiceClient(socketURL: socketURL)
        for method in LocalServiceServer.helperMethods.sorted() {
            let object = try JSONSerialization.jsonObject(with: client.request(method: method)) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, true, method)
        }
        for method in ["speech.status", "transcripts.search", "transcripts.recent", "activity.report", "speech.start"] {
            let object = try JSONSerialization.jsonObject(with: client.request(method: method)) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, false, method)
            XCTAssertTrue((object?["error"] as? String)?.contains("helper") == true, method)
        }
        let paths = seen.withLock { $0 }
        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }, "The predicate sees the peer's executable")
    }

    func testOtherPeersKeepEveryMethod() throws {
        let socketURL = directory.appendingPathComponent("service.sock")
        let server = LocalServiceServer(socketURL: socketURL, isHelper: { _ in false }) { _ in Data(#"{"ok":true,"result":{}}"#.utf8) }
        try server.start(); defer { server.stop() }
        let object = try JSONSerialization.jsonObject(with: LocalServiceClient(socketURL: socketURL).request(method: "speech.status")) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
    }

    func testBundledHelperMatchesOnlyThatAppsHelper() {
        let match = LocalServiceServer.bundledHelper(in: URL(fileURLWithPath: "/Applications/Jot.app"))
        XCTAssertTrue(match("/Applications/Jot.app/Contents/Helpers/jot-vorssaint"))
        XCTAssertFalse(match("/Applications/Jot.app/Contents/Helpers/jot"))
        XCTAssertFalse(match("/tmp/jot-vorssaint"))
    }
}
