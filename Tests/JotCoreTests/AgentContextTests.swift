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

    func testDuplicateHookEventIsStoredOnceAndClearInvalidatesIt() throws {
        let context = AgentContext()
        let first = try context.add(role: "assistant", source: "codex", conversation: "c1",
            text: "The focused conversation now has a unique result to inspect.", eventID: "event-1", now: now)
        let snapshot = context.sources(within: 600, now: now)
        let second = try context.add(role: "assistant", source: "codex", conversation: "c1",
            text: "The focused conversation now has a unique result to inspect.", eventID: "event-1", now: now)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(context.count, 1)
        XCTAssertTrue(context.matchesSnapshot(snapshot, latestID: first.id, within: 600, now: now))
        try context.add(role: "assistant", source: "claude-code", conversation: "other",
            text: "An unrelated worker completed another task", eventID: "event-2", now: now)
        XCTAssertTrue(context.matchesSnapshot(snapshot, latestID: first.id, within: 600, now: now), "Other conversations do not dismiss a card")
        try context.add(role: "user", source: "codex", conversation: "c1", text: "One more request", now: now)
        XCTAssertFalse(context.matchesSnapshot(snapshot, latestID: first.id, within: 600, now: now), "New words in this conversation invalidate the old draft")
        context.clear()
        XCTAssertFalse(context.matchesSnapshot(snapshot, latestID: first.id, within: 600, now: now))
        XCTAssertTrue(context.sources(within: 600, now: now).isEmpty)
    }

    func testOnlyUniqueVisibleConversationInCompatibleAppIsSelected() throws {
        let context = AgentContext()
        let first = "The export guard now rejects invalid input before any file is written."
        let second = "The sidebar redraw now follows every relevant state transition cleanly."
        try context.add(role: "user", source: "codex", conversation: "export", text: "Fix export", now: now)
        try context.add(role: "assistant", source: "codex", conversation: "export", text: first, now: now)
        try context.add(role: "assistant", source: "codex", conversation: "sidebar", text: second, now: now)
        let selected = context.sources(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: first)
        XCTAssertEqual(selected.map(\.scope.conversation), ["export", "export"])
        XCTAssertTrue(context.sources(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: first + " " + second).isEmpty)
        XCTAssertTrue(context.sources(within: 600, now: now, targetBundleID: "com.apple.MobileSMS", visibleText: first).isEmpty)
        XCTAssertTrue(context.sources(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: nil).isEmpty)
        XCTAssertTrue(context.sources(within: 600, now: now, targetBundleID: "com.openai.codex",
            visibleText: "The tests are passing now and everything looks good today").isEmpty)
    }

    func testMatchStateDistinguishesAbsentInvisibleAndAmbiguousAgentInputs() throws {
        let context = AgentContext()
        let first = "The export guard now rejects invalid input before any file is written."
        let second = "The sidebar redraw now follows every relevant state transition cleanly."
        XCTAssertEqual(context.match(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: first).state, .noMessages)
        try context.add(role: "assistant", source: "codex", conversation: "export", text: first, now: now)
        XCTAssertEqual(context.match(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: nil).state, .noVisibleMatch)
        XCTAssertEqual(context.match(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: first).state, .matched)
        try context.add(role: "assistant", source: "codex", conversation: "sidebar", text: second, now: now)
        XCTAssertEqual(context.match(within: 600, now: now, targetBundleID: "com.openai.codex", visibleText: first + " " + second).state, .ambiguousMatch)
    }

    func testTerminalMayMatchEitherProviderButNeverBoth() throws {
        let context = AgentContext()
        let claude = "The migration guard checks the schema before opening any persistent table."
        let codex = "The conversation matcher checks visible words before adding any agent source."
        try context.add(role: "assistant", source: "claude-code", conversation: "c", text: claude, now: now)
        try context.add(role: "assistant", source: "codex", conversation: "x", text: codex, now: now)
        XCTAssertEqual(context.sources(within: 600, now: now, targetBundleID: "com.apple.Terminal", visibleText: claude).map(\.origin), ["claude-code"])
        XCTAssertEqual(context.sources(within: 600, now: now, targetBundleID: "com.googlecode.iterm2", visibleText: codex).map(\.origin), ["codex"])
        XCTAssertTrue(context.sources(within: 600, now: now, targetBundleID: "com.apple.Terminal", visibleText: claude + " " + codex).isEmpty)
    }

    func testMetadataAndMessageCountAreBounded() throws {
        let context = AgentContext()
        XCTAssertThrowsError(try context.add(role: "user", source: "codex", conversation: String(repeating: "x", count: 201), text: "hi"))
        XCTAssertThrowsError(try context.add(role: "user", source: "codex", conversation: "c", text: "hi", cwd: String(repeating: "x", count: 1025)))
        try context.add(role: "user", source: "codex", conversation: "c", text: "hi", turn: "t1", cwd: "/tmp/project", now: now)
        XCTAssertEqual(context.sources(within: 600, now: now).first?.scope.project, "/tmp/project")
        for index in 0..<(AgentContext.maximumMessages + 2) {
            try context.add(role: "user", source: "codex", conversation: "c", text: "message \(index)", now: now)
        }
        XCTAssertEqual(context.count, AgentContext.maximumMessages)
    }

    func testUnscopedManualContextIsHeldButCannotLeakIntoOtherFields() throws {
        let context = AgentContext()
        let reply = "The export guard rejects malformed records before writing the destination file."
        try context.add(role: "assistant", source: "codex", text: reply, now: now)
        XCTAssertEqual(context.count, 1)
        XCTAssertTrue(context.sources(within: 600, now: now,
            targetBundleID: "com.openai.codex", visibleText: reply).isEmpty)
    }

    func testUnselectedOldMessageExpiringDoesNotInvalidateSelectedReply() throws {
        let context = AgentContext()
        try context.add(role: "user", source: "codex", conversation: "c", text: "old prompt",
            now: now.addingTimeInterval(-590))
        let reply = try context.add(role: "assistant", source: "codex", conversation: "c",
            text: "The export guard rejects malformed records before writing the destination file.",
            now: now.addingTimeInterval(-10))
        let chosen = context.sources(within: 600, now: now).filter { $0.id == reply.id }
        XCTAssertTrue(context.matchesSnapshot(chosen, latestID: reply.id, within: 600,
            now: now.addingTimeInterval(20)))
        XCTAssertFalse(context.matchesSnapshot(chosen, latestID: reply.id, within: 600,
            now: now.addingTimeInterval(601)))
    }
}
