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
