import Foundation
import XCTest
@testable import JotCore

final class StoreExecutorTests: XCTestCase {
    func testBlockingOperationLeavesMainActorResponsive() async throws {
        let executor = StoreExecutor(label: "Jot.test.store")
        let began = expectation(description: "database work began")
        let release = DispatchSemaphore(value: 0)
        let work = Task {
            try await executor.perform {
                XCTAssertFalse(Thread.isMainThread)
                began.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else {
                    throw StoreError.invalid("Main actor did not release the database operation")
                }
                return 42
            }
        }
        await fulfillment(of: [began], timeout: 2)
        _ = await MainActor.run { release.signal() }
        let result = try await work.value
        XCTAssertEqual(result, 42)
    }

    func testCancelledCallerStillFinishesSubmittedWrite() async throws {
        let executor = StoreExecutor(label: "Jot.test.store.cancel")
        let began = expectation(description: "write began")
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "write finished")
        let work = Task {
            try await executor.perform {
                began.fulfill()
                _ = release.wait(timeout: .now() + 3)
                finished.fulfill()
            }
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(executor.pendingCount, 1)
        work.cancel()
        release.signal()
        try await work.value
        await executor.flush()
        XCTAssertEqual(executor.pendingCount, 0)
        await fulfillment(of: [finished], timeout: 2)
    }

    func testFailureDoesNotPoisonFollowingWork() async throws {
        let executor = StoreExecutor(label: "Jot.test.store.error")
        do {
            _ = try await executor.perform { () -> Int in throw StoreError.invalid("expected") }
            XCTFail("Expected the operation's error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "expected")
        }
        let result = try await executor.perform { 7 }
        XCTAssertEqual(result, 7)
    }

    func testReadSeesWriteWhoseCallerWasCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(directory: directory)
        let executor = StoreExecutor(label: "Jot.test.store.order")
        let started = expectation(description: "write submitted")
        let release = DispatchSemaphore(value: 0)
        let writer = Task {
            try await executor.perform {
                started.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else {
                    throw StoreError.invalid("Write was not released")
                }
                try store.append(Transcript(id: "kept", sessionID: "session", startedAt: Date(),
                    startSeconds: 0, endSeconds: 1, text: "saved", mode: "dictation"))
            }
        }
        await fulfillment(of: [started], timeout: 2)
        writer.cancel()
        let reader = Task { try await executor.perform { try store.read(id: "kept") } }
        release.signal()
        let saved = try await reader.value
        try await writer.value
        XCTAssertEqual(saved?.text, "saved")
    }
}
