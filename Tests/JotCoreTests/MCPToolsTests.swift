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

    func testSinceTakesAnOptionalCursorSessionAndLimit() throws {
        let since = try tool("transcripts_since")
        XCTAssertEqual(since.method, .transcriptsSince)
        XCTAssertTrue(since.readOnly)
        XCTAssertNoThrow(try since.validate(arguments: [:]))
        XCTAssertNoThrow(try since.validate(arguments: decode(#"{"cursor": 0}"#)))
        XCTAssertNoThrow(try since.validate(arguments: decode(#"{"cursor": 7, "generation": "store-generation"}"#)))
        XCTAssertNoThrow(try since.validate(arguments: decode(#"{"cursor": 9007199254740991, "sessionID": "s1", "limit": 200}"#)))
        try assertRejects("transcripts_since", #"{"cursor": -1}"#, "cursor must be a nonnegative integer")
        try assertRejects("transcripts_since", #"{"cursor": "12"}"#, "cursor must be a nonnegative integer")
        try assertRejects("transcripts_since", #"{"cursor": 1.5}"#, "cursor must be a nonnegative integer")
        try assertRejects("transcripts_since", #"{"generation": ""}"#, "generation must be a nonempty string")
        try assertRejects("transcripts_since", #"{"generation": 1}"#, "generation must be a nonempty string")
        try assertRejects("transcripts_since", #"{"sessionID": ""}"#, "sessionID must be a nonempty string")
        try assertRejects("transcripts_since", #"{"limit": 201}"#, "limit exceeds its maximum")
        try assertRejects("transcripts_since", #"{"offset": 5}"#, "Unknown argument: offset")
    }

    func testWaitTakesTheFeedPositionAndABoundedTimeout() throws {
        let wait = try tool("transcripts_wait")
        XCTAssertEqual(wait.method, .transcriptsWait)
        XCTAssertTrue(wait.readOnly)
        XCTAssertTrue(wait.method.isLongRunning)
        XCTAssertNoThrow(try wait.validate(arguments: [:]))
        XCTAssertNoThrow(try wait.validate(arguments: decode(#"{"cursor": 7, "generation": "g", "sessionID": "s1", "limit": 200, "timeoutSeconds": 110}"#)))
        XCTAssertNoThrow(try wait.validate(arguments: decode(#"{"timeoutSeconds": 0}"#)))
        try assertRejects("transcripts_wait", #"{"timeoutSeconds": 111}"#, "timeoutSeconds exceeds its maximum")
        try assertRejects("transcripts_wait", #"{"timeoutSeconds": -1}"#, "timeoutSeconds must be a nonnegative integer")
        try assertRejects("transcripts_wait", #"{"timeoutSeconds": true}"#, "timeoutSeconds must be a nonnegative integer")
        try assertRejects("transcripts_wait", #"{"cursor": "3"}"#, "cursor must be a nonnegative integer")
        try assertRejects("transcripts_wait", #"{"offset": 1}"#, "Unknown argument: offset")
    }

    func testVocabularyToolsTakeBooleansAndBoundedText() throws {
        XCTAssertTrue(try tool("vocabulary_list").readOnly)
        let save = try tool("vocabulary_save")
        XCTAssertFalse(save.readOnly)
        XCTAssertNoThrow(try save.validate(arguments: decode(#"{"preferred": "Jot", "heard": "jot", "enabled": false}"#)))
        XCTAssertNoThrow(try save.validate(arguments: decode(#"{"id": "8B0F2C1E-6B1A-4C55-9E3B-1C1F4A7E2D10", "enabled": true}"#)))
        try assertRejects("vocabulary_save", #"{"preferred": "Jot", "enabled": 1}"#, "enabled must be true or false")
        try assertRejects("vocabulary_save", #"{"preferred": "Jot", "enabled": "yes"}"#, "enabled must be true or false")
        try assertRejects("vocabulary_save", #"{"preferred": "\#(String(repeating: "a", count: 201))"}"#, "preferred is too long")
        try assertRejects("vocabulary_remove", #"{}"#, "Missing argument: id")
    }

    func testNamesAndMethodsAreUniqueAndRequiredKeysAreDeclared() {
        let names = MCPTool.catalog.map(\.name), methods = MCPTool.catalog.map(\.method)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(methods).count, methods.count, "Each tool calls its own socket method")
        for tool in MCPTool.catalog { XCTAssertTrue(tool.required.allSatisfy { tool.properties[$0] != nil }, tool.name) }
    }

    func testOnlyReadingToolsAreReadOnly() {
        XCTAssertEqual(MCPTool.catalog.filter(\.readOnly).map(\.name), ["speech_status", "activity_report", "sessions_notes", "transcripts_search", "transcripts_recent",
                                                                        "transcripts_since", "transcripts_wait", "transcripts_read", "transcripts_sessions", "transcripts_export", "transcripts_events", "people_list", "vocabulary_list"])
    }
    func testActivityReportIsBoundedReadOnlyAndValidatesSocketArguments() throws {
        let activity = try tool("activity_report")
        XCTAssertEqual(activity.method, .activityReport)
        XCTAssertTrue(activity.readOnly)
        XCTAssertNoThrow(try activity.validate(arguments: [:]))
        XCTAssertNoThrow(try activity.validate(arguments: decode(#"{"days": 7}"#)))
        XCTAssertNoThrow(try activity.validate(arguments: decode(#"{"days": 30}"#)))
        for json in [#"{"days": 8}"#, #"{"days": true}"#, #"{"days": 7.5}"#, #"{"days": "7"}"#] {
            try assertRejects("activity_report", json, "days must be 7 or 30")
        }
        try assertRejects("activity_report", #"{"sessionID": "private"}"#, "Unknown argument: sessionID")
    }
    func testForgetUsesTheCanonicalSocketMethod() throws {
        let tool = try XCTUnwrap(MCPTool.catalog.first { $0.name == "people_forget" })
        XCTAssertEqual(tool.method, .peopleForget)
    }

}
