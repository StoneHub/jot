import XCTest
@testable import JotCore

final class SessionAudioTests: XCTestCase {
    func testStaleFilesAreEveryAudioFileExceptTheRunningSession() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-audio-" + UUID().uuidString)
        try SessionAudioPaths.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["old-a.f32", "running.f32", "old-b.f32", "notes.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        XCTAssertEqual(SessionAudioPaths.staleSessionIDs(except: "running", in: directory), ["old-a", "old-b"])
        XCTAssertEqual(SessionAudioPaths.url(sessionID: "running", in: directory).lastPathComponent, "running.f32")
    }

    func testMissingDirectoryHasNoStaleFiles() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(SessionAudioPaths.staleSessionIDs(except: "x", in: missing), [])
    }
}
