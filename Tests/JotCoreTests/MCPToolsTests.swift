import XCTest
@testable import JotCore

final class MCPToolsTests: XCTestCase {
    private func tool(_ name: String) throws -> MCPTool { try XCTUnwrap(MCPTool.catalog.first { $0.name == name }) }
    /// Decodes arguments the way `jot mcp` decodes a tools/call frame, so numbers and booleans arrive as NSNumber.
    private func decode(_ json: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) }
    private func assertRejects(_ name: String, _ json: String, _ message: String, line: UInt = #line) throws {
        let arguments = try decode(json)
        XCTAssertThrowsError(try tool(name).validate(arguments: arguments), line: line) { XCTAssertEqual($0.localizedDescription, message, line: line) }
    }

    func testRejectsUnknownMissingEmptyAndOverlongArguments() throws {
        try assertRejects("speech_status", #"{"bogus": 1}"#, "Unknown argument: bogus")
        try assertRejects("sessions_title", #"{"sessionID": "s1"}"#, "Missing argument: title")
        try assertRejects("sessions_title", #"{"sessionID": "s1", "title": ""}"#, "title must be a nonempty string")
        try assertRejects("sessions_title", #"{"sessionID": 5, "title": "Standup"}"#, "sessionID must be a nonempty string")
        try assertRejects("sessions_title", #"{"sessionID": "s1", "title": "\#(String(repeating: "a", count: 201))"}"#, "title is too long")
    }

    func testRejectsIntegersOutOfRangeOrOfTheWrongKind() throws {
        try assertRejects("transcripts_recent", #"{"limit": 0}"#, "limit is below its minimum")
        try assertRejects("transcripts_recent", #"{"limit": 201}"#, "limit exceeds its maximum")
        try assertRejects("transcripts_recent", #"{"limit": true}"#, "limit must be a nonnegative integer")
        try assertRejects("transcripts_recent", #"{"limit": 1.5}"#, "limit must be a nonnegative integer")
        try assertRejects("transcripts_recent", #"{"limit": "5"}"#, "limit must be a nonnegative integer")
        try assertRejects("transcripts_recent", #"{"offset": -1}"#, "offset must be a nonnegative integer")
    }

    func testAcceptsArgumentsAtTheirLimits() throws {
        XCTAssertNoThrow(try tool("speech_status").validate(arguments: [:]))
        XCTAssertNoThrow(try tool("transcripts_search").validate(arguments: decode(#"{"query": "budget", "limit": 200, "offset": 0}"#)))
        XCTAssertNoThrow(try tool("transcripts_recent").validate(arguments: decode(#"{"limit": 1, "offset": 40}"#)))
        XCTAssertNoThrow(try tool("sessions_title").validate(arguments: ["sessionID": "s1", "title": String(repeating: "a", count: 200)]))
    }

    func testNamesAndMethodsAreUniqueAndRequiredKeysAreDeclared() {
        let names = MCPTool.catalog.map(\.name), methods = MCPTool.catalog.map(\.method)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(methods).count, methods.count, "Each tool calls its own socket method")
        for tool in MCPTool.catalog { XCTAssertTrue(tool.required.allSatisfy { tool.properties[$0] != nil }, tool.name) }
    }

    func testOnlyReadingToolsAreReadOnly() {
        XCTAssertEqual(MCPTool.catalog.filter(\.readOnly).map(\.name), ["speech_status", "speech_doctor", "transcripts_search", "transcripts_recent",
                                                                        "transcripts_read", "transcripts_sessions", "transcripts_export", "transcripts_events", "people_list"])
    }
}
