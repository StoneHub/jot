import XCTest
@testable import JotCore

final class ModelCacheTests: XCTestCase {
    private func makeFile(_ directory: URL, _ name: String, bytes: Int) throws {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: file)
    }

    func testEmptyOrMissingCacheReportsZeroSoTheFirstResumeAsksBeforeDownloading() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(ModelCache.bytesOnDisk(at: missing), 0)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertEqual(ModelCache.bytesOnDisk(at: missing), 0)
    }

    func testCachedBytesSumEveryFileAcrossNestedModelDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeFile(root, "parakeet/Encoder.mlmodelc/weights/weight.bin", bytes: 900)
        try makeFile(root, "parakeet/Decoder.mlmodelc/model.mil", bytes: 90)
        try makeFile(root, "silero/model.bin", bytes: 10)
        XCTAssertEqual(ModelCache.bytesOnDisk(at: root), 1000)
    }

    func testExpectedTotalMatchesTheListedModelsSoThePromptAndRowsAgree() {
        XCTAssertEqual(ModelCache.expectedBytes, ModelCache.expected.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(ModelCache.expected.count, 3)
        XCTAssertTrue(ModelCache.expected.allSatisfy { $0.bytes > 0 && !$0.purpose.isEmpty })
    }

    func testSizesReadAsMegabytesBelowAGigabyteAndGigabytesAbove() {
        XCTAssertTrue(ModelCache.formatted(483_257_242).hasSuffix("MB"), ModelCache.formatted(483_257_242))
        XCTAssertTrue(ModelCache.formatted(2_000_000_000).hasSuffix("GB"), ModelCache.formatted(2_000_000_000))
    }
}
