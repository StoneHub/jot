import XCTest
@testable import JotCore

final class MicrophoneSelectionTests: XCTestCase {
    func testSavedMicrophoneIsUsedWhenConnected() {
        XCTAssertEqual(MicrophoneSelection.captureUID(saved: "usb-1", available: ["built-in", "usb-1"]), "usb-1")
    }
    func testDisconnectedSavedMicrophoneFallsBackToSystemDefault() {
        XCTAssertNil(MicrophoneSelection.captureUID(saved: "usb-1", available: ["built-in"]))
    }
    func testNothingSavedUsesSystemDefault() {
        XCTAssertNil(MicrophoneSelection.captureUID(saved: nil, available: ["built-in"]))
        XCTAssertNil(MicrophoneSelection.captureUID(saved: "", available: ["built-in", ""]))
    }
}
