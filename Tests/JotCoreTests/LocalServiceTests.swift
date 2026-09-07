import XCTest
@testable import JotCore
import Darwin

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
}
