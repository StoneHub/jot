import XCTest
@testable import JotCore

final class SuggestionEvaluationInteractionTests: XCTestCase {
    // Recorded physical Fn sequence: macOS emits key 179 down/up immediately after release.
    func testFnReleaseCompanionEventsDoNotBreakDoubleTap() {
        let trace: [(ShortcutTracker.Event, UInt16, ShortcutModifiers, TimeInterval)] = [
            (.flagsChanged, 63, [.fn], 0), (.flagsChanged, 63, [], 0.052),
            (.keyDown, 179, [], 0.0521), (.keyUp, 179, [], 0.0522),
            (.flagsChanged, 63, [.fn], 0.110), (.flagsChanged, 63, [], 0.157),
            (.keyDown, 179, [], 0.1571), (.keyUp, 179, [], 0.1572)
        ]
        var paused = SuggestionFnGesture(), listening = ShortcutTracker()
        var requests = 0, recoveries = 0
        for (event, code, flags, time) in trace {
            if paused.handle(event, keyCode: code, modifiers: flags, at: time, enabled: true) { requests += 1 }
            if listening.handle(event, keyCode: code, modifiers: flags, shortcut: .fn, at: time).action == .recover { recoveries += 1 }
        }
        XCTAssertEqual(requests, 1, "Paused Fn request must survive release companion events")
        XCTAssertEqual(recoveries, 1, "Listening uses the same double-tap recognition")
    }

    func testFnCompanionEventsCannotDismissQueuedOrVisibleSuggestion() {
        for state: SuggestionKeyTracker.State in [.requesting, .loading, .ready] {
            var tracker = SuggestionKeyTracker(); tracker.show(state)
            for code: UInt16 in [63, 179] {
                for event: ShortcutTracker.Event in [.keyDown, .keyUp] {
                    XCTAssertEqual(tracker.handle(event, keyCode: code, modifiers: [], shortcut: nil, allowed: true), .init())
                    XCTAssertEqual(tracker.state, state)
                }
            }
            XCTAssertEqual(tracker.handle(.keyDown, keyCode: 0, modifiers: [], shortcut: nil, allowed: true), .init(.dismiss))
        }
    }

    func testFnRequestsOnSecondShortReleaseButNeverOnHold() {
        var gesture = SuggestionFnGesture()
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 0, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 0.1, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 0.2, enabled: true))
        XCTAssertTrue(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 0.3, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 1, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 2, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 2.1, enabled: true))
        XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 2.2, enabled: true))
    }

    func testFnTypingModifiersDisableAndSlowTapsBreakTheSequence() {
        for interruption in 0..<4 {
            var gesture = SuggestionFnGesture()
            _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: 0, enabled: true)
            _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 0.1, enabled: true)
            switch interruption {
            case 0: _ = gesture.handle(.keyDown, keyCode: 0, modifiers: [], at: 0.15, enabled: true)
            case 1: _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn, .shift], at: 0.15, enabled: true)
            case 2: _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: 0.15, enabled: false)
            default: break
            }
            let start: TimeInterval = interruption == 3 ? 1 : 0.2
            _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: [.fn], at: start, enabled: true)
            XCTAssertFalse(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], at: start + 0.1, enabled: true))
        }
    }

    func testPlaceholderIsNotDraftTextAndAmbiguousAXValuesAbstain() throws {
        let blank = try XCTUnwrap(SuggestionDraftSnapshot.accessibilityDraft(value: "Do anything", placeholder: "Do anything",
            characterCount: 0, location: 0, length: 0))
        XCTAssertEqual(blank.value, "")
        XCTAssertEqual(blank.mode(bundleID: "com.openai.codex", role: "AXTextArea"), .reply)
        XCTAssertNil(SuggestionDraftSnapshot.accessibilityDraft(value: "Do anything", placeholder: "Do anything",
            characterCount: nil, location: 0, length: 0))
        XCTAssertNil(SuggestionDraftSnapshot.accessibilityDraft(value: "unidentified hint", placeholder: nil,
            characterCount: 0, location: 0, length: 0))
    }

    func testActuallyTypedPlaceholderWordsRemainUserText() throws {
        let typed = try XCTUnwrap(SuggestionDraftSnapshot.accessibilityDraft(value: "Do anything", placeholder: "Do anything",
            characterCount: 11, location: 11, length: 0))
        XCTAssertEqual(typed.value, "Do anything")
        XCTAssertEqual(typed.mode(bundleID: "com.openai.codex", role: "AXTextArea"), .continuation)
        XCTAssertNil(SuggestionDraftSnapshot.accessibilityDraft(value: "changed", placeholder: nil,
            characterCount: 4, location: 4, length: 0))
    }

    func testOutputCannotEchoPlaceholderOrEntireDraft() throws {
        let blank = try XCTUnwrap(SuggestionDraftSnapshot(value: "", location: 0, length: 0))
        XCTAssertTrue(SuggestionOutput.isFieldEcho("  DO   anything ", draft: blank, placeholder: "Do anything"))
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "Explain the failure", location: 19, length: 0))
        XCTAssertTrue(SuggestionOutput.isFieldEcho("Explain the failure", draft: draft, placeholder: nil))
        XCTAssertFalse(SuggestionOutput.isFieldEcho(" without changing files.", draft: draft, placeholder: "Do anything"))
    }

    func testAutomaticSuggestionsWaitForStableDraftAndDoNotRepeatDismissedDraft() {
        var trigger = SuggestionAutomaticTrigger<String>()
        XCTAssertFalse(trigger.observe("draft", at: 0))
        XCTAssertFalse(trigger.observe("draft", at: 0.5))
        XCTAssertFalse(trigger.observe("edited draft", at: 0.6))
        XCTAssertFalse(trigger.observe("edited draft", at: 1))
        XCTAssertTrue(trigger.observe("edited draft", at: 1.4))
        XCTAssertFalse(trigger.observe("edited draft", at: 30))
        XCTAssertFalse(trigger.observe(nil, at: 31))
        XCTAssertFalse(trigger.observe("edited draft", at: 32))
        XCTAssertFalse(trigger.observe("edited draft", at: 33))
    }

    func testNewContextCanSuggestInAnUnchangedDraft() {
        struct Key: Equatable { let draft: String; let revision: Int }
        var trigger = SuggestionAutomaticTrigger<Key>()
        let first = Key(draft: "", revision: 1), newSpeech = Key(draft: "", revision: 2)
        XCTAssertFalse(trigger.observe(first, at: 0))
        XCTAssertTrue(trigger.observe(first, at: 1))
        XCTAssertFalse(trigger.observe(first, at: 10))
        XCTAssertFalse(trigger.observe(newSpeech, at: 11))
        XCTAssertTrue(trigger.observe(newSpeech, at: 12))
    }

    func testAutomaticSuggestionsRespectCooldownAndDoNotCompleteTheirOwnInsertion() {
        var trigger = SuggestionAutomaticTrigger<String>()
        XCTAssertFalse(trigger.observe("a", at: 0))
        XCTAssertTrue(trigger.observe("a", at: 1))
        XCTAssertFalse(trigger.observe("b", at: 1.1))
        XCTAssertFalse(trigger.observe("b", at: 2))
        XCTAssertTrue(trigger.observe("b", at: 3))
        trigger.suppress("accepted text", at: 3.5)
        XCTAssertFalse(trigger.observe("accepted text", at: 10))
        XCTAssertFalse(trigger.observe("user edit", at: 11))
        XCTAssertTrue(trigger.observe("user edit", at: 12))
    }

    private let shortcut = DictationShortcut(keyCode: 38, modifiers: [.control, .option], keyLabel: "J")
    private func key(_ tracker: inout SuggestionKeyTracker, _ code: UInt16 = 48,
                     event: ShortcutTracker.Event = .keyDown, flags: ShortcutModifiers = [], repeating: Bool = false,
                     allowed: Bool = true) -> SuggestionKeyTracker.Decision {
        tracker.handle(event, keyCode: code, modifiers: flags, repeating: repeating, shortcut: shortcut, allowed: allowed)
    }

    func testTabPassesWithoutReadyCardAndAfterTyping() {
        var tracker = SuggestionKeyTracker()
        XCTAssertFalse(key(&tracker).consume)
        tracker.show(.loading)
        XCTAssertEqual(key(&tracker), .init(.dismiss))
        tracker.show(.ready)
        XCTAssertEqual(key(&tracker, 0), .init(.dismiss))
        XCTAssertFalse(key(&tracker).consume)
        XCTAssertFalse(key(&tracker, 48, event: .keyUp).consume)
    }

    func testAcceptedTabConsumesExactlyItsPairDespiteDismissalAndModifierRelease() {
        var tracker = SuggestionKeyTracker()
        tracker.show(.ready)
        XCTAssertEqual(key(&tracker), .init(.accept, consume: true))
        tracker.dismiss()
        XCTAssertEqual(key(&tracker, 48, event: .keyUp, flags: [.shift]), .init(consume: true))
        XCTAssertFalse(key(&tracker, 48, event: .keyUp).consume)
        XCTAssertFalse(key(&tracker).consume)
    }

    func testModifiedAndRepeatedTabNeverAccept() {
        for flags: ShortcutModifiers in [[.shift], [.control], [.option], [.command]] {
            var tracker = SuggestionKeyTracker(); tracker.show(.ready)
            XCTAssertEqual(key(&tracker, flags: flags), .init(.dismiss))
            XCTAssertFalse(key(&tracker, event: .keyUp, flags: flags).consume)
        }
        var tracker = SuggestionKeyTracker(); tracker.show(.ready)
        XCTAssertEqual(key(&tracker, repeating: true), .init(.dismiss))
    }

    func testEscapeConsumesOnlyWithVisibleCard() {
        var tracker = SuggestionKeyTracker()
        XCTAssertFalse(key(&tracker, 53).consume)
        tracker.show(.requesting)
        XCTAssertEqual(key(&tracker, 53), .init(.dismiss))
        for state: SuggestionKeyTracker.State in [.loading, .ready, .notice] {
            tracker.show(state)
            XCTAssertEqual(key(&tracker, 53), .init(.dismiss, consume: true))
            XCTAssertTrue(key(&tracker, 53, event: .keyUp).consume)
            XCTAssertFalse(key(&tracker, 53).consume)
        }
    }

    func testBusyOrIMEPreflightCannotStartOrAcceptAndRequestUpIsPaired() {
        var tracker = SuggestionKeyTracker()
        XCTAssertFalse(key(&tracker, 38, flags: shortcut.modifiers, allowed: false).consume)
        XCTAssertEqual(key(&tracker, 38, flags: shortcut.modifiers), .init(.request, consume: true))
        XCTAssertTrue(key(&tracker, 38, event: .keyUp).consume)
        tracker.show(.ready)
        XCTAssertEqual(key(&tracker, allowed: false), .init(.dismiss))
    }

    func testSameLengthDraftAndSelectionChangesHaveDifferentSnapshots() throws {
        let first = try XCTUnwrap(SuggestionDraftSnapshot(value: "fix guard", location: 9, length: 0))
        let edited = try XCTUnwrap(SuggestionDraftSnapshot(value: "add guard", location: 9, length: 0))
        XCTAssertEqual(first.value.count, edited.value.count)
        XCTAssertNotEqual(first, edited); XCTAssertNotEqual(first.revision, edited.revision)
        let selection = try XCTUnwrap(SuggestionDraftSnapshot(value: "fix guard", location: 0, length: 3))
        XCTAssertNotEqual(first, selection)
        XCTAssertEqual(selection.before, ""); XCTAssertEqual(selection.after, " guard")
        let emoji = try XCTUnwrap(SuggestionDraftSnapshot(value: "Hi 👋!", location: 5, length: 0))
        XCTAssertEqual(emoji.before, "Hi 👋"); XCTAssertEqual(emoji.after, "!")
        XCTAssertNil(SuggestionDraftSnapshot(value: "x", location: 2, length: 0))
        XCTAssertNil(SuggestionDraftSnapshot(value: "x", location: 0, length: 2))
    }

    func testBlankFieldRequiresCodexComposerAndOtherDraftsUseContinuation() throws {
        let blank = try XCTUnwrap(SuggestionDraftSnapshot(value: "", location: 0, length: 0))
        XCTAssertEqual(blank.mode(bundleID: "com.openai.codex", role: "AXTextArea"), .reply)
        XCTAssertNil(blank.mode(bundleID: "com.openai.codex", role: "AXTextField"))
        XCTAssertNil(blank.mode(bundleID: "com.apple.Safari", role: "AXTextArea"))
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "Please ", location: 7, length: 0))
        XCTAssertEqual(draft.mode(bundleID: "com.apple.TextEdit", role: "AXTextArea"), .continuation)
    }

    func testContinuationKeepsTheSeparatorNeededAtTheCursor() {
        XCTAssertEqual(SuggestionOutput.process(" and rerun the tests.", mode: .continuation),
                       .suggestion(" and rerun the tests."))
        XCTAssertEqual(SuggestionOutput.process("\" and rerun the tests.\"", mode: .continuation),
                       .suggestion(" and rerun the tests."))
        XCTAssertEqual(SuggestionOutput.process("  NO_SUGGESTION  ", mode: .continuation), .abstained("model-abstained"))
        XCTAssertEqual(SuggestionOutput.process("  ", mode: .continuation), .abstained("empty-output"))
    }

    func testShortcutIsUnassignedUntilChosenAndConflictsAreRejected() throws {
        let name = "suggestion-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SuggestionShortcutPreferences(defaults: defaults)
        XCTAssertNil(preferences.load())
        XCTAssertThrowsError(try preferences.save(.fn, dictation: .fn))
        XCTAssertThrowsError(try preferences.save(shortcut, dictation: shortcut))
        try preferences.save(shortcut, dictation: .fn)
        XCTAssertEqual(preferences.load(), shortcut)
    }

    func testExplicitContextPreservesRolesAndDoesNotChangeCorpusScopeRules() {
        let rows = [
            Transcript(id: "d", sessionID: "d", startedAt: Date(), startSeconds: 0, endSeconds: 1, text: "Explain the failing test.", mode: "dictation"),
            Transcript(id: "m", sessionID: "m", startedAt: Date(), startSeconds: 0, endSeconds: 1, text: "I will send it.", mode: "ambient")
        ]
        let context = SuggestionContext(rows: rows, sessionTitle: "Standup")
        XCTAssertEqual(context.sources.map(\.role), ["user", "participant"])
        XCTAssertEqual(context.sources[1].speaker, "unlabeled speaker")
        XCTAssertFalse(context.sources.contains { $0.kind == "pinned-selection" })
        let target = Target(app: "Codex", mode: .reply, purpose: "agent-prompt", before: "", after: "", requestedAt: "now")
        XCTAssertTrue(SourceSelector.select(ScenarioInput(target: target, sources: context.sources)).selected.isEmpty)
        XCTAssertEqual(SourceSelector.select(context.input(target: target)).selected.count, 2)
        XCTAssertEqual(SourceSelector.select(context.input(target: target, association: .automaticRecentContext)).selected, context.sources)
        XCTAssertEqual(context.attribution(selected: context.sources), "Recent dictation + Meeting ‘Standup’")
    }

    func testStoreContextUsesTimeWindowLatestSessionAndRevalidatesEditsAndDeletion() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory), now = Date(timeIntervalSince1970: 10_000)
        func row(_ id: String, session: String, age: Double, mode: String) -> Transcript {
            Transcript(id: id, sessionID: session, startedAt: now.addingTimeInterval(-age), startSeconds: 0, endSeconds: 1,
                       text: "Synthetic " + id, speakerID: "speaker-1", mode: mode)
        }
        try store.append(row("old", session: "old", age: 1801, mode: "dictation"))
        try store.append(row("other", session: "other", age: 100, mode: "ambient"))
        try store.append(row("future", session: "future", age: -100, mode: "ambient"))
        try store.append(row("latest", session: "latest", age: 30, mode: "ambient"))
        try store.append(row("dictation", session: "dictation", age: 60, mode: "dictation"))
        try store.setTitle(sessionID: "latest", title: "Standup")
        let context = try store.suggestionContext(now: now)
        XCTAssertEqual(Set(context.rows.map(\.id)), ["latest", "dictation"])
        XCTAssertEqual(context.sessionTitle, "Standup")
        XCTAssertTrue(try store.suggestionRowsUnchanged(context.rows))
        try store.label(sessionID: "latest", speakerID: "speaker-1", name: "Rowan")
        XCTAssertFalse(try store.suggestionRowsUnchanged(context.rows))
        let refreshed = try store.suggestionContext(now: now)
        XCTAssertEqual(refreshed.sources.first { $0.id == "latest" }?.speaker, "Rowan")
        let dictation = try XCTUnwrap(refreshed.rows.first { $0.id == "dictation" })
        try store.setReadablePhrase(["Changed synthetic request"], for: [dictation])
        XCTAssertFalse(try store.suggestionRowsUnchanged(refreshed.rows))
        let edited = try store.suggestionContext(now: now)
        XCTAssertTrue(try store.suggestionRowsUnchanged(edited.rows))
        try store.deleteTranscripts(ids: ["dictation"])
        XCTAssertFalse(try store.suggestionRowsUnchanged(edited.rows))
        XCTAssertEqual(try store.suggestionContext(now: now).rows.map(\.id), ["latest"])
    }

    @MainActor func testDismissalCancelsCallerButKeepsGateClosedUntilGeneratorReturns() async {
        actor Blocker {
            var continuation: CheckedContinuation<String, Never>?
            var released = false
            func wait() async -> String {
                if released { return "late" }
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() { released = true; continuation?.resume(returning: "late"); continuation = nil }
        }
        let blocker = Blocker(), gate = ModelCallGate(deadline: .seconds(10))
        let started = expectation(description: "generator started")
        let request = ModelRequest(instructions: "test", prompt: "test", maximumResponseTokens: 1)
        let task = Task { await gate.call(request) { _ in
            started.fulfill(); return await blocker.wait()
        } }
        await fulfillment(of: [started], timeout: 1)
        gate.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, .cancelled)
        let blocked = await gate.call(request) { _ in XCTFail("overlap"); return "bad" }
        XCTAssertEqual(blocked, .blocked)
        await blocker.release()
        let settled = await gate.settle(within: .seconds(1))
        XCTAssertTrue(settled)
    }
}
