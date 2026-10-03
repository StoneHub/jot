import AppleFM
import XCTest
@testable import JotCore

final class WindowImageGenerationTests: XCTestCase {
    func testImageRejectionWithoutTextContextDoesNotRetryTheModel() async throws {
        for rejection in [AppleFMError.imageUnsupported(.visionUnsupported), .unreadableImage] {
            let result = try await WindowImageGeneration.run(allowsTextOnly: false, image: { throw rejection }, text: {
                XCTFail("An image-only reply or continuation has no grounding after image rejection")
                return "Invented continuation"
            })
            XCTAssertEqual(result, .needsContext)
            XCTAssertNil(result.text)
            XCTAssertFalse(result.usedImage)
        }
    }

    func testRejectedImageFallsBackToGroundedTextAndIsNotAttributed() async throws {
        let result = try await WindowImageGeneration.run(allowsTextOnly: true,
            image: { throw AppleFMError.imageUnsupported(.requiresNewerOS) }, text: { "The grounded draft" })
        XCTAssertEqual(result, .text("The grounded draft"))
        XCTAssertFalse(result.usedImage)
        XCTAssertEqual(SuggestionAttribution.line(plan: .continuation, selected: [], sessionTitle: nil,
                                                  windowImage: result.usedImage), "Your text")
    }

    func testSuccessfulImageDoesNotCallTextFallbackAndRemainsAttributed() async throws {
        let result = try await WindowImageGeneration.run(allowsTextOnly: false, image: { "The visible conversation" }, text: {
            XCTFail("An accepted image needs no retry")
            return "unused"
        })
        XCTAssertEqual(result, .image("The visible conversation"))
        XCTAssertTrue(result.usedImage)
        XCTAssertEqual(SuggestionAttribution.line(plan: .reply, selected: [], sessionTitle: nil,
                                                  windowImage: result.usedImage), "An image of the window")
    }

    func testCancellationAfterImageRejectionDoesNotStartTextGeneration() async {
        let caller = Task {
            try await WindowImageGeneration.run(allowsTextOnly: true, image: {
                withUnsafeCurrentTask { $0?.cancel() }
                throw AppleFMError.imageUnsupported(.visionUnsupported)
            }, text: {
                XCTFail("A dismissed request must not start a second model call")
                return "unused"
            })
        }
        do {
            _ = try await caller.value
            XCTFail("Cancellation must propagate instead of retrying")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private actor Rejections {
        var count = 0
        func record() { count += 1 }
        func recorded() -> Int { count }
    }

    func testRejectionIsRecordedBeforeATextFallbackThatFails() async {
        enum Failure: Error { case synthetic }
        let rejections = Rejections()
        do {
            _ = try await WindowImageGeneration.run(allowsTextOnly: true, onRejected: { await rejections.record() },
                image: { throw AppleFMError.unreadableImage }, text: {
                    let recorded = await rejections.recorded()
                    XCTAssertEqual(recorded, 1, "Image provenance must change before the text call starts")
                    throw Failure.synthetic
                })
            XCTFail("The fallback error must propagate")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        let recorded = await rejections.recorded()
        XCTAssertEqual(recorded, 1, "A failed fallback still records rejection exactly once")
    }

    @MainActor
    func testRejectionIsRecordedBeforeATextFallbackTimesOut() async {
        actor Blocker {
            var continuation: CheckedContinuation<String, Never>?
            var released = false
            func wait() async -> String {
                if released { return "late text" }
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() { released = true; continuation?.resume(returning: "late text"); continuation = nil }
        }
        let rejections = Rejections(), blocker = Blocker()
        let gate = ModelCallGate(deadline: .milliseconds(20))
        let request = ModelRequest(instructions: "Synthetic", prompt: "Grounded text", maximumResponseTokens: 1)
        let result = await gate.call(request) { _ in
            let generated = try await WindowImageGeneration.run(allowsTextOnly: true,
                onRejected: { await rejections.record() }, image: { throw AppleFMError.imageUnsupported(.visionUnsupported) },
                text: { await blocker.wait() })
            return generated.text ?? SuggestionPrompt.abstainMarker
        }
        XCTAssertEqual(result, .timedOut)
        let recorded = await rejections.recorded()
        XCTAssertEqual(recorded, 1, "Receipt provenance changes before the model gate's deadline, not after late completion")
        await blocker.release()
        let settled = await waitForModelGate(gate, within: .seconds(1))
        XCTAssertTrue(settled)
    }

    func testOtherImageErrorsDoNotInvokeTextFallback() async {
        enum Failure: Error { case synthetic }
        do {
            _ = try await WindowImageGeneration.run(allowsTextOnly: true, image: { throw Failure.synthetic }, text: {
                XCTFail("Only unsupported or unreadable images permit a fallback")
                return "unused"
            })
            XCTFail("The image error must remain a failure")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }
}
