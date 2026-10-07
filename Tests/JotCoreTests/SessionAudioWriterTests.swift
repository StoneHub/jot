import XCTest
@testable import JotCore

final class SessionAudioWriterTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-audio-writes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("synthetic.f32") }
    private func writer(queue: DispatchQueue, bytes: Int = 16, packets: Int = 2, fileBytes: Int = 4096) -> SessionAudioWriter {
        .init(url: url, byteLimit: fileBytes, pendingByteLimit: bytes, maximumPendingPackets: packets, queue: queue)
    }
    private func floats() throws -> [Float] {
        let bytes = try Data(contentsOf: url)
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testNormalSamplesAndSilenceRemainOrderedAndFinishClosesAdmission() async throws {
        let writer = SessionAudioWriter(url: url, byteLimit: 4096)
        writer.append([1, 2]); writer.appendSilence(samples: 2); writer.append([3])
        let finished = try await writer.finish()
        let outcome = try XCTUnwrap(finished)
        XCTAssertEqual(outcome.bytes, 20); XCTAssertFalse(outcome.truncated)
        XCTAssertEqual(try floats(), [1, 2, 0, 0, 3])
        XCTAssertEqual(writer.bufferedBytes, 0); XCTAssertEqual(writer.pendingPacketCount, 0)
        writer.append([4]); writer.appendSilence(samples: 1)
        XCTAssertEqual(try floats(), [1, 2, 0, 0, 3])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, 0o600)
    }

    func testBlockedWriterNeverRetainsPastTheByteBudgetAndFailsTheFile() async throws {
        let queue = DispatchQueue(label: "audio-test.byte-budget")
        queue.suspend()
        let writer = writer(queue: queue)
        writer.append([1, 2]); writer.appendSilence(samples: 2)
        XCTAssertEqual(writer.bufferedBytes, 16); XCTAssertEqual(writer.pendingPacketCount, 2)
        writer.append([3])
        for _ in 0..<1000 { writer.append([4]); writer.appendSilence(samples: Int.max) }
        XCTAssertLessThanOrEqual(writer.bufferedBytes, 16); XCTAssertLessThanOrEqual(writer.pendingPacketCount, 2)
        queue.resume()
        do { _ = try await writer.finish(); XCTFail("Overflow must prevent an offline speaker pass") }
        catch { XCTAssertTrue(error is SessionAudioWriter.Failure) }
        XCTAssertEqual(writer.bufferedBytes, 0); XCTAssertEqual(writer.pendingPacketCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPacketBudgetBoundsTinyPacketsEvenWhenByteBudgetHasRoom() async throws {
        let queue = DispatchQueue(label: "audio-test.packet-budget")
        queue.suspend()
        let writer = writer(queue: queue, bytes: 4096)
        writer.append([1]); writer.append([2]); writer.append([3])
        XCTAssertLessThanOrEqual(writer.pendingPacketCount, 2)
        queue.resume()
        do { _ = try await writer.finish(); XCTFail("Too many packets must fail admission") }
        catch { XCTAssertTrue(error is SessionAudioWriter.Failure) }
        XCTAssertEqual(writer.pendingPacketCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileLimitKeepsOnlyAContinuousPrefixIncludingSilence() async throws {
        let queue = DispatchQueue(label: "audio-test.prefix")
        queue.suspend()
        let writer = writer(queue: queue, bytes: 4096, packets: 10, fileBytes: 16)
        writer.append([1, 2]); writer.appendSilence(samples: Int.max); writer.append([3, 4])
        XCTAssertEqual(writer.bufferedBytes, 16); XCTAssertEqual(writer.pendingPacketCount, 2)
        queue.resume()
        let finished = try await writer.finish()
        let outcome = try XCTUnwrap(finished)
        XCTAssertEqual(outcome.bytes, 16); XCTAssertTrue(outcome.truncated)
        XCTAssertEqual(try floats(), [1, 2, 0, 0])
    }

    func testDiscardWhileBlockedClosesAdmissionAndDrainsWithoutCreatingAFile() async throws {
        let queue = DispatchQueue(label: "audio-test.discard")
        queue.suspend()
        let writer = writer(queue: queue)
        writer.append([1, 2]); writer.discard(); writer.discard(); writer.append([3, 4])
        XCTAssertEqual(writer.bufferedBytes, 8); XCTAssertEqual(writer.pendingPacketCount, 1)
        queue.resume()
        let finished = try await writer.finish()
        XCTAssertNil(finished)
        XCTAssertEqual(writer.bufferedBytes, 0); XCTAssertEqual(writer.pendingPacketCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteFailureReleasesReservationsAndNeverReturnsAudio() async throws {
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("parent"))
        let bad = SessionAudioWriter(url: directory.appendingPathComponent("parent/audio.f32"), byteLimit: 16)
        bad.append([1, 2])
        do { _ = try await bad.finish(); XCTFail("Cannot return unwritten audio") } catch {}
        XCTAssertEqual(bad.bufferedBytes, 0); XCTAssertEqual(bad.pendingPacketCount, 0)
        bad.append([3]); XCTAssertEqual(bad.pendingPacketCount, 0)
    }

    func testCancelledFinishWaiterDoesNotCancelAlreadyAdmittedWrites() async throws {
        let queue = DispatchQueue(label: "audio-test.cancel")
        queue.suspend()
        let writer = writer(queue: queue)
        writer.append([1, 2])
        let finish = Task { try await writer.finish() }
        finish.cancel()
        queue.resume()
        let finished = try await finish.value
        let outcome = try XCTUnwrap(finished)
        XCTAssertEqual(outcome.bytes, 8); XCTAssertEqual(try floats(), [1, 2])
        XCTAssertEqual(writer.bufferedBytes, 0); XCTAssertEqual(writer.pendingPacketCount, 0)
        writer.discard()
        let discarded = try await writer.finish()
        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOverflowRemovesAnAlreadyWrittenPrefixInsteadOfReturningDiscontinuousAudio() async throws {
        let queue = DispatchQueue(label: "audio-test.written-prefix")
        let writer = writer(queue: queue)
        writer.append([1, 2])
        queue.sync {}
        XCTAssertEqual(try floats(), [1, 2])
        queue.suspend()
        writer.append([3, 4]); writer.append([5, 6]); writer.append([7])
        queue.resume()
        do { _ = try await writer.finish(); XCTFail("A prefix followed by an overflow is unavailable") }
        catch { XCTAssertTrue(error is SessionAudioWriter.Failure) }
        XCTAssertEqual(writer.bufferedBytes, 0); XCTAssertEqual(writer.pendingPacketCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileLimitClipsAPacketBeforeRetainingIt() async throws {
        let queue = DispatchQueue(label: "audio-test.clip-packet")
        queue.suspend()
        let writer = writer(queue: queue, fileBytes: 16)
        writer.append((0..<5000).map(Float.init))
        XCTAssertEqual(writer.bufferedBytes, 16); XCTAssertEqual(writer.pendingPacketCount, 1)
        queue.resume()
        let finished = try await writer.finish()
        let outcome = try XCTUnwrap(finished)
        XCTAssertEqual(outcome.bytes, 16); XCTAssertTrue(outcome.truncated)
        XCTAssertEqual(try floats(), [0, 1, 2, 3])
    }

    func testEmptyAndDiscardedWritersReturnNoFile() async throws {
        let writer = SessionAudioWriter(url: url, byteLimit: 16)
        writer.append([]); writer.appendSilence(samples: 0)
        let finished = try await writer.finish()
        XCTAssertNil(finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
