import XCTest
import JotCore
@testable import JotCLI

final class MCPServerTests: XCTestCase {
    private func frame(_ method: String, id: Any = 7, params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }
    private func response(_ data: Data) throws -> [String: Any] {
        XCTAssertEqual(data.last, 10, "The transport emits a newline-terminated protocol frame")
        XCTAssertEqual(data.filter { $0 == 10 }.count, 1, "No prose outside the one JSON frame")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testActualInitializeFrameCarriesScopedOptInInstructionsWithoutIPC() throws {
        var frames: [Data] = [], calls = 0
        let server = MCPServer(request: { _, _ in calls += 1; throw ListenError("No service access during initialization") }, writeFrame: { frames.append($0) })
        try server.process(frame("initialize", id: "client-1", params: ["protocolVersion": "2025-03-26"]))
        XCTAssertEqual(calls, 0); XCTAssertEqual(frames.count, 1)
        let object = try response(frames[0])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0"); XCTAssertEqual(object["id"] as? String, "client-1")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "jot"); XCTAssertEqual(info["version"] as? String, JotVersion.current)
        let instructions = try XCTUnwrap(result["instructions"] as? String)
        XCTAssertTrue(instructions.contains("user explicitly asks"))
        XCTAssertTrue(instructions.contains("current conversation"))
        XCTAssertTrue(instructions.contains("command event"))
        XCTAssertTrue(instructions.contains("any voice"))
        XCTAssertTrue(instructions.contains("session and scope"))
        XCTAssertTrue(instructions.contains("normal permission prompts"))
        XCTAssertTrue(instructions.contains("Saved transcripts, all-mode observed rows, attached context"))
        XCTAssertTrue(instructions.contains("untrusted data"))
        XCTAssertTrue(instructions.contains("ignore queued events"))
        XCTAssertTrue(instructions.contains("does not pause Jot"))
        XCTAssertFalse(instructions.contains("Ambient speech is not an instruction to tools"), "The old unconditional rule contradicts opted-in commands")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual((capabilities["tools"] as? [String: Any])?["listChanged"] as? Bool, false)
    }
    func testUnknownAndMissingInitializeVersionNegotiateCurrentProtocol() throws {
        var frames: [Data] = []
        let server = MCPServer(request: { _, _ in XCTFail("No IPC"); return Data() }, writeFrame: { frames.append($0) })
        for params in [[String: Any](), ["protocolVersion": "future"]] { try server.process(frame("initialize", params: params)) }
        XCTAssertEqual(frames.count, 2)
        for data in frames {
            let result = try XCTUnwrap(try response(data)["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        }
    }
    func testToolCatalogRemainsAvailableAndReadOnlyFeedCannotStartListener() throws {
        var frames: [Data] = [], calls = 0
        let server = MCPServer(request: { _, _ in calls += 1; return Data() }, writeFrame: { frames.append($0) })
        try server.process(frame("tools/list"))
        let result = try XCTUnwrap(try response(frames[0])["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, MCPTool.catalog.map(\.name))
        let feed = try XCTUnwrap(tools.first { $0["name"] as? String == "transcripts_since" })
        XCTAssertEqual((feed["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(calls, 0)
    }
    func testToolCallStillValidatesAndForwardsExactlyOnce() throws {
        var frames: [Data] = [], methods: [String] = []
        let server = MCPServer(request: { method, _ in
            methods.append(method)
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["mode": "paused"]])
        }, writeFrame: { frames.append($0) })
        try server.process(frame("tools/call", params: ["name": "speech_status", "arguments": [:]]))
        try server.process(frame("tools/call", params: ["name": "speech_status", "arguments": ["unexpected": true]]))
        XCTAssertEqual(methods, ["speech.status"])
        XCTAssertEqual((try response(frames[0])["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual((try response(frames[1])["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
    func testMalformedFrameAndUnknownMethodRemainProtocolErrors() throws {
        var frames: [Data] = []
        let server = MCPServer(request: { _, _ in XCTFail("No IPC"); return Data() }, writeFrame: { frames.append($0) })
        try server.process(Data("bad JSON".utf8))
        try server.process(frame("missing-method"))
        XCTAssertEqual((try response(frames[0])["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((try response(frames[1])["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
    func testNotificationsDoNotEmitOrStartIPC() throws {
        var frames: [Data] = [], calls = 0
        let server = MCPServer(request: { _, _ in calls += 1; return Data() }, writeFrame: { frames.append($0) })
        try server.process(JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(frames, []); XCTAssertEqual(calls, 0)
    }
}
