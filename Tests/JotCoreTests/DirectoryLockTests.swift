import XCTest
@testable import JotCore

final class DirectoryLockTests: XCTestCase {
    func testASecondLockOnTheSameDirectoryIsRefusedUntilTheFirstIsReleased() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: DirectoryLock? = try DirectoryLock(directory: directory)
        XCTAssertEqual(first?.url.lastPathComponent, DirectoryLock.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(DirectoryLock.fileName).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "The lock file is user-only, like the rest of the directory")
        XCTAssertThrowsError(try DirectoryLock(directory: directory)) { error in
            XCTAssertEqual(error as? DirectoryLock.Failure, .held(directory.path))
            XCTAssertTrue(error.localizedDescription.contains("Another Jot is already using"))
        }
        first = nil
        XCTAssertNoThrow(try DirectoryLock(directory: directory), "Releasing the first lock frees the directory")
    }

    func testTheLockCreatesTheDirectoryItGuards() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathComponent("Jot")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let lock = try DirectoryLock(directory: directory)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        _ = lock
    }
}
