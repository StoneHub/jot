import XCTest
@testable import JotCore

/// The optional window image for suggestions: which window, which part of it, how it is sized, and what the request and
/// its receipt say about it. Capture itself needs a screen and Screen Recording, so it is checked on the Mac.
final class WindowImageTests: XCTestCase {
    private typealias Window = WindowImageGeometry.Window
    private let chat = CGRect(x: 100, y: 50, width: 1000, height: 800)
    private let composer = CGRect(x: 300, y: 700, width: 400, height: 40)

    func testMatchesTheFieldsOwnWindowOnly() {
        let windows = [
            Window(id: 1, pid: 42, frame: CGRect(x: 1200, y: 50, width: 600, height: 400), layer: 0),
            Window(id: 2, pid: 42, frame: chat.offsetBy(dx: 3, dy: -2), layer: 0),
            Window(id: 3, pid: 7, frame: chat, layer: 0),
            Window(id: 4, pid: 42, frame: chat, layer: 25),
        ]
        XCTAssertEqual(WindowImageGeometry.window(among: windows, pid: 42, windowFrame: chat, field: composer)?.id, 2)
        // Another window of the app is never taken for the field's window.
        XCTAssertNil(WindowImageGeometry.window(among: windows, pid: 42, windowFrame: chat.offsetBy(dx: 40, dy: 0), field: composer))
        XCTAssertNil(WindowImageGeometry.window(among: windows, pid: 99, windowFrame: chat, field: composer))
    }

    func testWithoutAWindowFrameOnlyOneContainingWindowCounts() {
        let one = [Window(id: 1, pid: 42, frame: chat, layer: 0),
                   Window(id: 2, pid: 42, frame: CGRect(x: 1200, y: 50, width: 600, height: 400), layer: 0)]
        XCTAssertEqual(WindowImageGeometry.window(among: one, pid: 42, windowFrame: nil, field: composer)?.id, 1)
        let overlapping = one + [Window(id: 3, pid: 42, frame: chat.insetBy(dx: 50, dy: 50), layer: 0)]
        XCTAssertNil(WindowImageGeometry.window(among: overlapping, pid: 42, windowFrame: nil, field: composer))
    }

    func testFrameMatchingDropsAmbiguousWindowsEvenWhenOneIsCloser() {
        let windows = [Window(id: 1, pid: 42, frame: chat, layer: 0),
                       Window(id: 2, pid: 42, frame: chat.offsetBy(dx: 4, dy: 0), layer: 0)]
        XCTAssertNil(WindowImageGeometry.window(among: windows, pid: 42, windowFrame: chat, field: composer),
                     "Both windows fit the Accessibility tolerance; neither is safe to capture")
    }

    func testRegionRunsFromTheWindowTopToTheFieldInItsColumn() throws {
        let region = try XCTUnwrap(WindowImageGeometry.region(window: chat, field: composer))
        XCTAssertEqual(region, CGRect(x: 200, y: 0, width: 400, height: 690))
    }

    func testANarrowFieldKeepsOnlyItsActualColumn() throws {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let region = try XCTUnwrap(WindowImageGeometry.region(window: window, field: CGRect(x: 10, y: 700, width: 100, height: 30)))
        XCTAssertEqual(region, CGRect(x: 10, y: 0, width: 100, height: 730))
        let right = try XCTUnwrap(WindowImageGeometry.region(window: window, field: CGRect(x: 950, y: 100, width: 40, height: 20)))
        XCTAssertEqual(right, CGRect(x: 950, y: 0, width: 40, height: 120))
        XCTAssertNil(WindowImageGeometry.region(window: window, field: CGRect(x: 1200, y: 100, width: 40, height: 20)))
    }

    func testReviewedComposerDoesNotExpandIntoTheAdjacentSidebar() throws {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let field = CGRect(x: 300, y: 700, width: 700, height: 40)
        let region = try XCTUnwrap(WindowImageGeometry.region(window: window, field: field))
        XCTAssertEqual(region, CGRect(x: 300, y: 0, width: 700, height: 740))
    }

    func testAFieldCrossingWindowEdgesIsIntersectedWithoutShiftingItsColumn() throws {
        let left = try XCTUnwrap(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 80, y: 700, width: 100, height: 40)))
        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 80, height: 690))
        let right = try XCTUnwrap(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 1050, y: 700, width: 100, height: 40)))
        XCTAssertEqual(right, CGRect(x: 950, y: 0, width: 50, height: 690))
    }

    func testTheVerticalRegionStillEndsAtTheFieldBottomClippedToTheWindow() throws {
        let region = try XCTUnwrap(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 300, y: 830, width: 400, height: 50)))
        XCTAssertEqual(region, CGRect(x: 200, y: 0, width: 400, height: 800))
        XCTAssertNil(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 300, y: 0, width: 400, height: 40)))
    }

    func testTooLittleHorizontalOverlapSkipsTheImageRatherThanWideningIt() {
        XCTAssertNil(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 300, y: 700, width: 15, height: 40)))
        XCTAssertNil(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 1090, y: 700, width: 40, height: 40)))
        XCTAssertEqual(WindowImageGeometry.region(window: chat,
            field: CGRect(x: 300, y: 700, width: 16, height: 40)),
            CGRect(x: 200, y: 0, width: 16, height: 690))
    }

    func testCaptureSizeKeepsTheLongerSideWithinTheLimit() {
        let small = WindowImageGeometry.pixelSize(of: CGSize(width: 1000, height: 800), scale: 2)
        XCTAssertEqual(small?.width, 2000); XCTAssertEqual(small?.height, 1600)
        let large = WindowImageGeometry.pixelSize(of: CGSize(width: 1600, height: 1000), scale: 2)
        XCTAssertEqual(large?.width, WindowImageGeometry.maximumSide); XCTAssertEqual(large?.height, 1280)
        XCTAssertNil(WindowImageGeometry.pixelSize(of: .zero, scale: 2))
        XCTAssertNil(WindowImageGeometry.pixelSize(of: CGSize(width: 10, height: 10), scale: 0))
    }

    func testRegionMapsIntoTheCapturedImage() {
        let region = CGRect(x: 200, y: 0, width: 400, height: 690)
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 2000, height: 1600)),
                       CGRect(x: 400, y: 0, width: 800, height: 1380))
        // A smaller image scales the region down with it.
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 1000, height: 800)),
                       CGRect(x: 200, y: 0, width: 400, height: 690))
        XCTAssertNil(WindowImageGeometry.pixelRegion(CGRect(x: 2000, y: 0, width: 10, height: 10), window: chat.size,
                                                     image: (width: 1000, height: 800)))
    }

    func testFractionalPixelEdgesRoundInsideTheHorizontalColumnOnly() {
        let region = CGRect(x: 200.25, y: 0, width: 400.5, height: 690.25)
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 2000, height: 1600)),
                       CGRect(x: 401, y: 0, width: 800, height: 1381))
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 1000, height: 800)),
                       CGRect(x: 201, y: 0, width: 399, height: 691))
        XCTAssertNil(WindowImageGeometry.pixelRegion(CGRect(x: 40.1, y: 0, width: 0.3, height: 20),
                                                     window: chat.size, image: (width: 1000, height: 800)))
    }

    @MainActor
    func testOptionalContextIsDroppedOnceItsTimeRunsOut() async {
        let quick = Task<Int, Never> { 7 }
        let value = await ModelCallGate.value(of: quick, within: .seconds(5))
        XCTAssertEqual(value, 7)
        let slow = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(3600))
            return 8
        }
        let late = await ModelCallGate.value(of: slow, within: .milliseconds(20))
        XCTAssertNil(late)
        XCTAssertTrue(slow.isCancelled)
    }

    @MainActor
    func testCancellingOptionalContextDropsALateValueAndCancelsItsWork() async {
        actor Blocker {
            var continuation: CheckedContinuation<Int, Never>?
            var released = false
            func wait() async -> Int {
                if released { return 8 }
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() { released = true; continuation?.resume(returning: 8); continuation = nil }
        }
        let blocker = Blocker()
        let started = expectation(description: "capture started")
        let finished = expectation(description: "cancelled caller released before capture returns")
        let capture = Task.detached {
            started.fulfill()
            return await blocker.wait() // Deliberately ignores cancellation, as a native API may.
        }
        let caller = Task {
            let value = await ModelCallGate.value(of: capture, within: .seconds(10))
            finished.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 1)
        caller.cancel()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(capture.isCancelled)
        await blocker.release()
        let value = await caller.value
        XCTAssertNil(value, "A dismissed request must never receive the late image")
    }

    func testImageInstructionsPreserveScopedContinuationAndSelectedRewrite() throws {
        let source = SuggestionSource(id: "agent", kind: AgentContext.kind, role: "assistant", origin: "codex",
            scope: .init(project: "harbor", conversation: "thread"), timestamp: "2026-09-27T11:59:00Z",
            revision: 1, status: .current, text: "The harbor export now handles empty files.")
        for mode in [SuggestionMode.continuation, .draft] {
            let target = SuggestionTarget(app: "Codex", mode: mode, purpose: "agent-prompt", project: "harbor",
                conversation: "thread", before: "Summarize the harbor export", after: " Keep the suffix.",
                requestedAt: "2026-09-27T12:00:00Z", seed: mode == .draft ? "rough notes about harbor export" : nil)
            let input = SuggestionRequest(target: target, sources: [source])
            let selected = SourceSelector.select(input).selected
            XCTAssertEqual(selected.map(\.id), ["agent"])
            let text = SuggestionPrompt.request(for: input, sources: selected)
            let image = SuggestionPrompt.addingWindowImage(to: text)
            XCTAssertEqual(image.prompt, text.prompt)
            XCTAssertEqual(image.maximumResponseTokens, text.maximumResponseTokens)
            XCTAssertEqual(image.instructions, text.instructions + " " + SuggestionPrompt.windowImageInstruction)
            XCTAssertTrue(image.prompt.contains("harbor"))
            XCTAssertTrue(image.prompt.contains("Keep the suffix."))
            if mode == .continuation {
                XCTAssertTrue(image.instructions.contains("The text before the cursor is the user's own words"))
            } else {
                XCTAssertTrue(image.prompt.contains("rough notes about harbor export"))
            }
        }
        let draft = try XCTUnwrap(SuggestionDraftSnapshot(value: "before chosen notes after", location: 7, length: 12))
        guard case .draft(let seed) = SuggestionPlan.make(draft: draft, role: "AXTextArea", hasAssociatedContext: true) else {
            return XCTFail("An image must keep selection rewrite semantics")
        }
        XCTAssertEqual(seed.text, "chosen notes")
        XCTAssertEqual(draft.text(around: seed).before, "before ")
        XCTAssertEqual(draft.text(around: seed).after, " after")
    }

    func testAnImageAddsOneSentenceAndChangesNothingElse() {
        let text = ModelRequest(instructions: "Write the reply.", prompt: "Field: chat.", maximumResponseTokens: 128)
        let image = SuggestionPrompt.addingWindowImage(to: text)
        XCTAssertEqual(image.instructions, "Write the reply. " + SuggestionPrompt.windowImageInstruction)
        XCTAssertEqual(image.prompt, text.prompt)
        XCTAssertEqual(image.maximumResponseTokens, text.maximumResponseTokens)
        XCTAssertTrue(SuggestionPrompt.windowImageInstruction.contains("quoted data"))
        XCTAssertTrue(SuggestionPrompt.windowImageInstruction.contains("do not guess who said what"))
        XCTAssertEqual(SuggestionPrompt.windowImageTemplateID, SuggestionPrompt.templateID + "-window-image")
    }

    func testAttributionNamesTheImage() {
        XCTAssertEqual(SuggestionAttribution.line(plan: .reply, selected: [], sessionTitle: nil, windowImage: true),
                       "An image of the window")
        XCTAssertEqual(SuggestionAttribution.line(plan: .reply, selected: [], sessionTitle: nil), "")
    }

    func testReceiptsRecordTheOutcomeAndOlderReceiptsStillDecode() throws {
        func entry(_ outcome: SuggestionHistoryEntry.WindowImageOutcome?, milliseconds: Int? = nil) -> SuggestionHistoryEntry {
            SuggestionHistoryEntry(id: UUID(), revision: 0, startedAt: Date(), appBundleID: "com.apple.MobileSMS",
                                   fieldRole: .textArea, purpose: .textEntry, plan: .reply, mode: .reply,
                                   beforeEndsSentence: true, draftCharacters: 0, selectionCharacters: 0,
                                   windowImage: outcome, windowImageMilliseconds: milliseconds)
        }
        XCTAssertEqual(entry(.attached, milliseconds: 90).templateID, SuggestionPrompt.windowImageTemplateID)
        XCTAssertEqual(entry(.noPermission).templateID, SuggestionPrompt.templateID)
        XCTAssertEqual(entry(nil).templateID, SuggestionPrompt.templateID)
        XCTAssertNoThrow(try entry(.attached, milliseconds: 60_000).validate())
        XCTAssertThrowsError(try entry(.captureTimedOut, milliseconds: 60_001).validate())

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry(.attached, milliseconds: 90))) as? [String: Any])
        XCTAssertEqual(object["windowImage"] as? String, "attached")
        object["windowImage"] = nil; object["windowImageMilliseconds"] = nil
        let older = try JSONDecoder().decode(SuggestionHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.windowImage)
        XCTAssertNil(older.windowImageMilliseconds)
    }

    func testTheImageIsOffUntilChosen() throws {
        let defaults = MemoryDefaults()
        XCTAssertFalse(JotSettings(defaults: defaults).bool(JotDefaultsKey.suggestionWindowImage))
    }
}
