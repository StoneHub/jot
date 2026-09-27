import XCTest
@testable import JotCore

final class AgentContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    func testMessagesInTheWindowBecomeSourcesOldestFirst() throws {
        let context = AgentContext()
        try context.add(role: "assistant", source: "claude-code", conversation: "c1", text: "Tests pass. Merge?", now: now.addingTimeInterval(-500))
        try context.add(role: "user", source: "claude-code", conversation: "c1", text: "  yes, merge it  ", now: now.addingTimeInterval(-10))
        let sources = context.sources(within: 600, now: now)
        XCTAssertEqual(sources.map(\.role), ["assistant", "user"])
        XCTAssertEqual(sources.map(\.text), ["Tests pass. Merge?", "yes, merge it"])
        XCTAssertEqual(sources.map(\.kind), [AgentContext.kind, AgentContext.kind])
        XCTAssertEqual(sources.first?.origin, "claude-code")
        XCTAssertEqual(sources.first?.scope.conversation, "c1")
        XCTAssertLessThan(sources[0].timestamp, sources[1].timestamp)
        XCTAssertEqual(context.count, 2)
    }

    func testMessagesOlderThanTheWindowAreForgotten() throws {
        let context = AgentContext()
        try context.add(role: "user", source: "codex", text: "old", now: now.addingTimeInterval(-601))
        try context.add(role: "user", source: "codex", text: "new", now: now)
        XCTAssertEqual(context.sources(within: 600, now: now).map(\.text), ["new"])
        XCTAssertEqual(context.count, 1, "An expired message is gone, not hidden")
        XCTAssertEqual(context.sources(within: 60, now: now.addingTimeInterval(61)), [])
        XCTAssertEqual(context.count, 0)
    }

    func testBoundsAreEnforced() throws {
        let context = AgentContext()
        XCTAssertThrowsError(try context.add(role: "system", source: "codex", text: "x", now: now))
        XCTAssertThrowsError(try context.add(role: "user", source: "  ", text: "x", now: now))
        XCTAssertThrowsError(try context.add(role: "user", source: "codex", text: " \n", now: now))
        XCTAssertThrowsError(try context.add(role: "user", source: "codex", text: String(repeating: "a", count: AgentContext.maximumMessageBytes + 1), now: now))
        XCTAssertEqual(context.count, 0)
        let big = String(repeating: "b", count: AgentContext.maximumMessageBytes)
        for _ in 0..<(AgentContext.maximumBytes / AgentContext.maximumMessageBytes + 2) {
            try context.add(role: "user", source: "codex", text: big, now: now)
        }
        XCTAssertEqual(context.count, AgentContext.maximumBytes / AgentContext.maximumMessageBytes, "The oldest go first when the total is over the bound")
        context.clear()
        XCTAssertEqual(context.count, 0)
    }

    func testTheSocketToolsAcceptTheirArguments() throws {
        let add = try XCTUnwrap(MCPTool.catalog.first { $0.name == "context_add" })
        XCTAssertEqual(add.method, "context.add")
        XCTAssertFalse(add.readOnly)
        XCTAssertNoThrow(try add.validate(arguments: ["role": "user", "source": "claude-code", "text": "hi"]))
        XCTAssertThrowsError(try add.validate(arguments: ["role": "user", "source": "claude-code"]))
        XCTAssertThrowsError(try add.validate(arguments: ["role": "user", "source": "claude-code", "text": "hi", "extra": 1]))
        XCTAssertEqual(MCPTool.catalog.first { $0.name == "context_clear" }?.method, "context.clear")
    }
}
