import XCTest
@testable import JotCore

/// Synthetic Claude Code sessions only; no real conversation text.
final class ConversationContextTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func update(_ session: String, _ event: ConversationUpdate.Event, prompt: String? = nil, reply: String? = nil) -> ConversationUpdate {
        ConversationUpdate(sessionID: session, event: event, cwd: "/tmp/project", prompt: prompt, reply: reply)!
    }

    func testUpdatesAreCappedAndNeedASessionAndWords() throws {
        let long = String(repeating: "a", count: 4500) + "END"
        let stop = try XCTUnwrap(ConversationUpdate(sessionID: "s", event: .stopped, prompt: "START" + long, reply: long))
        XCTAssertEqual(stop.prompt?.count, ConversationContext.maximumCharacters)
        XCTAssertTrue(stop.prompt!.hasPrefix("START") && stop.prompt!.hasSuffix("…"), "A prompt keeps its start")
        XCTAssertEqual(stop.reply?.count, ConversationContext.maximumCharacters)
        XCTAssertTrue(stop.reply!.hasPrefix("…") && stop.reply!.hasSuffix("END"), "A reply keeps its end")

        XCTAssertNil(ConversationUpdate(sessionID: "  ", event: .stopped, prompt: "p", reply: "r"))
        XCTAssertNil(ConversationUpdate(sessionID: "s", event: .stopped, prompt: " \n", reply: nil), "No words, no update")
        XCTAssertNil(ConversationUpdate(sessionID: "s", event: .promptSubmitted, prompt: nil, reply: "r"), "A prompt event carries no reply")
        XCTAssertNil(ConversationUpdate(params: ["sessionID": "s", "event": "SubagentStop", "prompt": "p"]))

        let submitted = update("s", .promptSubmitted, prompt: "  Run the tests  ")
        XCTAssertEqual(submitted.prompt, "Run the tests")
        let echoed = try XCTUnwrap(ConversationUpdate(params: submitted.params))
        XCTAssertEqual(echoed, submitted, "The CLI's params are what the service reads")
    }

    func testPromptsPairWithRepliesAndOnlyTheLatestExchangesStay() {
        var context = ConversationContext()
        context.record(update("s", .promptSubmitted, prompt: "Why does export pause?"), at: start)
        context.record(update("s", .stopped, prompt: "Why does export pause? (as the transcript shows it)", reply: "It waits on cleanup."),
                       at: start + 30)
        XCTAssertEqual(context.sessions.first?.exchanges.map(\.prompt), ["Why does export pause?"], "The submitted words win")
        XCTAssertEqual(context.sessions.first?.exchanges.map(\.reply), ["It waits on cleanup."])

        context.record(update("s", .stopped, prompt: "Why does export pause?", reply: "It waits on cleanup; a hook asked for more."),
                       at: start + 40)
        XCTAssertEqual(context.sessions.first?.exchanges.count, 1, "A second Stop for the same turn replaces its reply")
        XCTAssertEqual(context.sessions.first?.exchanges.last?.reply, "It waits on cleanup; a hook asked for more.")

        // Installed mid-session: no UserPromptSubmit, the Stop brings the prompt from the transcript.
        context.record(update("s", .stopped, prompt: "Add a test", reply: "Added."), at: start + 60)
        XCTAssertEqual(context.sessions.first?.exchanges.map(\.prompt), ["Why does export pause?", "Add a test"])
        for turn in 1...4 {
            context.record(update("s", .promptSubmitted, prompt: "Prompt \(turn)"), at: start + 60 + Double(turn))
        }
        XCTAssertEqual(context.sessions.first?.exchanges.map(\.prompt), ["Prompt 2", "Prompt 3", "Prompt 4"])
        XCTAssertEqual(context.sessions.count, 1)
        XCTAssertNil(context.sessions.first?.exchanges.last?.reply, "A prompt waits for its reply")
        XCTAssertEqual(context.sessions.first?.cwd, "/tmp/project")
    }

    func testSessionsAreBoundedAndExpire() {
        var context = ConversationContext()
        for index in 0..<6 { context.record(update("s\(index)", .promptSubmitted, prompt: "p\(index)"), at: start + Double(index)) }
        XCTAssertEqual(context.sessions.map(\.id), ["s5", "s4", "s3", "s2"], "Newest first, at most four")
        context.record(update("s2", .stopped, prompt: "p2", reply: "r2"), at: start + 10)
        XCTAssertEqual(context.sessions.first?.id, "s2", "An update moves its session to the front")

        let later = start + 10 + ConversationContext.lifetime + 1
        XCTAssertEqual(context.metadata(at: later)["sessions"] as? Int, 0)
        XCTAssertTrue(context.sessions(for: .claudeApp, at: later).isEmpty, "An hour-old conversation is not offered")
        context.record(update("new", .promptSubmitted, prompt: "p"), at: later)
        XCTAssertEqual(context.sessions.map(\.id), ["new"], "Recording drops expired sessions")
    }

    func testTerminalsTakeOnlyAFreshConversationAndOtherAppsNone() {
        XCTAssertEqual(ConversationContext.Surface(bundleID: "com.anthropic.claudefordesktop"), .claudeApp)
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
            XCTAssertEqual(ConversationContext.Surface(bundleID: terminal), .terminal, terminal)
        }
        XCTAssertNil(ConversationContext.Surface(bundleID: "com.openai.codex"))
        XCTAssertNil(ConversationContext.Surface(bundleID: "com.tinyspeck.slackmacgap"))

        var context = ConversationContext()
        context.record(update("s", .stopped, prompt: "p", reply: "r"), at: start)
        XCTAssertEqual(context.sessions(for: .terminal, at: start + 299).count, 1)
        XCTAssertEqual(context.sessions(for: .terminal, at: start + 301).count, 0, "A terminal needs a conversation from the last five minutes")
        XCTAssertEqual(context.sessions(for: .claudeApp, at: start + 3000).count, 1)
    }

    func testShownTextChoosesTheSessionOrDeclinesAnotherConversation() {
        var context = ConversationContext()
        context.record(update("a", .stopped, prompt: "Rename the export button",
                              reply: "I renamed the export button to Save transcript and updated the tests that looked for it."), at: start)
        context.record(update("b", .stopped, prompt: "Why is the speaker pass slow",
                              reply: "The speaker pass reloads its models for every session because Pause releases them."), at: start + 5)
        let candidates = context.sessions(for: .claudeApp, at: start + 10)
        XCTAssertEqual(ConversationContext.session(among: candidates, shown: nil)?.id, "b", "Without shown text, the newest")

        let filler = "Earlier in this chat we compared three sketches of the settings window and picked the calmer layout for now."
        let showingA = filler + "\n**I renamed** the export button to `Save transcript` and\nupdated the tests that looked for it."
        XCTAssertEqual(ConversationContext.session(among: candidates, shown: showingA)?.id, "a",
                       "The session whose words are shown wins, whatever Markdown and wrapping did to them")
        let otherChat = filler + " Then we talked about lunch options near the office and whether the new place takes reservations."
        XCTAssertNil(ConversationContext.session(among: candidates, shown: otherChat),
                     "A screen full of another conversation, such as Claude's chat tab, declines the Code conversation")
        XCTAssertEqual(ConversationContext.session(among: candidates, shown: "Claude Code New session")?.id, "b",
                       "A few words of window chrome decide nothing")
        XCTAssertNil(ConversationContext.session(among: [], shown: nil))
    }

    func testSourcesFitTheBudgetAndAttributeTheirAuthors() throws {
        var context = ConversationContext()
        context.record(update("s", .stopped, prompt: "Old question", reply: "Old answer"), at: start)
        let reply = "BEGIN " + String(repeating: "word ", count: 900) + "Should I also update the README?"
        context.record(update("s", .promptSubmitted, prompt: "Fix the pause bug and explain what changed"), at: start + 60)
        context.record(update("s", .stopped, prompt: nil, reply: reply), at: start + 90)
        let session = try XCTUnwrap(context.sessions.first)

        let sources = session.sources()
        XCTAssertEqual(sources.map(\.role), ["user", "assistant"], "An older exchange that no longer fits stays out whole")
        XCTAssertLessThanOrEqual(sources.reduce(0) { $0 + $1.text.utf8.count }, ConversationContext.maximumSourceBytes)
        XCTAssertEqual(sources[0].text, "Fix the pause bug and explain what changed")
        XCTAssertTrue(sources[1].text.hasPrefix("…") && sources[1].text.hasSuffix("Should I also update the README?"),
                      "The reply keeps its end, what the user answers")
        XCTAssertTrue(sources.allSatisfy { $0.kind == ConversationContext.kind && $0.scope.conversation == "s" })
        XCTAssertLessThan(sources[0].timestamp, sources[1].timestamp)

        let roomy = session.sources(maximumBytes: 10_000)
        XCTAssertEqual(roomy.map(\.text).first, "Old question", "Older exchanges join whole when they fit")
        XCTAssertEqual(roomy.count, 4)

        let target = Target(app: "Claude", mode: .reply, purpose: "agent-prompt", before: "", after: "", requestedAt: "2027-01-15T08:00:00Z")
        var input = ScenarioInput(target: target, sources: sources)
        input.association = .explicitRecentRequest
        let selection = SourceSelector.select(input)
        XCTAssertEqual(selection.selected.count, 2, "The conversation fits the selector's bounds whole")
        XCTAssertEqual(SuggestionAttribution.line(plan: .reply, selected: selection.selected, sessionTitle: nil), "The Claude Code conversation")
        let prompt = SuggestionPrompt.prompt(for: input, sources: selection.selected)
        XCTAssertTrue(prompt.contains("claude code conversation, from the user: \"Fix the pause bug"))
        XCTAssertTrue(prompt.contains("claude code conversation, from the assistant, not the user: \"…"))
        let notes = SuggestionPlan.draft(SuggestionSeed(text: "yes", location: 0, length: 3, isSelection: false))
        XCTAssertEqual(SuggestionAttribution.line(plan: notes, selected: selection.selected, sessionTitle: nil),
                       "Your notes + the Claude Code conversation")
    }

    func testClippingKeepsWholeCharactersWithinTheByteBound() {
        let text = "héllo wörld 👋 done"
        for limit in 0...text.utf8.count + 1 {
            for keepingEnd in [false, true] {
                let clipped = ConversationContext.clipped(text, maximumBytes: limit, keepingEnd: keepingEnd)
                XCTAssertLessThanOrEqual(clipped.utf8.count, limit)
                if limit >= text.utf8.count { XCTAssertEqual(clipped, text) }
            }
        }
    }

    func testStatusMetadataCarriesNoText() {
        var context = ConversationContext()
        XCTAssertEqual(context.metadata(at: start)["sessions"] as? Int, 0)
        XCTAssertNil(context.metadata(at: start)["secondsSinceUpdate"])
        context.record(update("secret-session", .stopped, prompt: "secret prompt", reply: "secret reply"), at: start)
        let metadata = context.metadata(at: start + 42)
        XCTAssertEqual(metadata["sessions"] as? Int, 1)
        XCTAssertEqual(metadata["secondsSinceUpdate"] as? Int, 42)
        XCTAssertEqual(Set(metadata.keys), ["sessions", "secondsSinceUpdate"])
        XCTAssertFalse(MCPTool.catalog.contains { $0.method.hasPrefix("conversation.") }, "No MCP tool reads or writes the conversation")
    }
}
