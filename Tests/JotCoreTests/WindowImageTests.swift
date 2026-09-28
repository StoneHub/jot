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

    func testRegionRunsFromTheWindowTopToTheFieldInItsColumn() throws {
        let region = try XCTUnwrap(WindowImageGeometry.region(window: chat, field: composer))
        // 1.3 × 400 = 520 points wide, centred on the field, from the window's top to the field's bottom.
        XCTAssertEqual(region, CGRect(x: 140, y: 0, width: 520, height: 690))
    }

    func testANarrowFieldStillGetsHalfTheWindowWithinItsEdges() throws {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let region = try XCTUnwrap(WindowImageGeometry.region(window: window, field: CGRect(x: 10, y: 700, width: 100, height: 30)))
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 500, height: 730))
        let right = try XCTUnwrap(WindowImageGeometry.region(window: window, field: CGRect(x: 950, y: 100, width: 40, height: 20)))
        XCTAssertEqual(right, CGRect(x: 500, y: 0, width: 500, height: 120))
        XCTAssertNil(WindowImageGeometry.region(window: window, field: CGRect(x: 1200, y: 100, width: 40, height: 20)))
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
        let region = CGRect(x: 140, y: 0, width: 520, height: 690)
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 2000, height: 1600)),
                       CGRect(x: 280, y: 0, width: 1040, height: 1380))
        // A smaller image scales the region down with it.
        XCTAssertEqual(WindowImageGeometry.pixelRegion(region, window: chat.size, image: (width: 1000, height: 800)),
                       CGRect(x: 140, y: 0, width: 520, height: 690))
        XCTAssertNil(WindowImageGeometry.pixelRegion(CGRect(x: 2000, y: 0, width: 10, height: 10), window: chat.size,
                                                     image: (width: 1000, height: 800)))
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
        let suite = "WindowImageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(JotSettings(defaults: defaults).bool(JotDefaultsKey.suggestionWindowImage))
    }
}
