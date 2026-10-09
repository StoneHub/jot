import AVFoundation
import XCTest
@testable import JotCore

final class TuningAudioTests: XCTestCase {
    private var directory: URL!
    private var kept: URL { directory.appendingPathComponent("tuning-audio", isDirectory: true) }
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-tuning-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A finished session file as the pass gets it: the samples' Float32 bytes, no header.
    private func sessionFile(_ samples: [Float]) throws -> URL {
        let url = directory.appendingPathComponent("session.f32")
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
        return url
    }

    private func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    private func permissions(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
    private func write(_ name: String, bytes: Int, written: Date) throws {
        let url = kept.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
    }

    func testHeaderDescribesMonoSixteenKilohertzFloat() {
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x3e, 0x00, 0x00, 0x00,  // "RIFF", 62 bytes follow: 50 of header and 12 of samples
            0x57, 0x41, 0x56, 0x45,                          // "WAVE"
            0x66, 0x6d, 0x74, 0x20, 0x12, 0x00, 0x00, 0x00,  // "fmt ", 18 bytes
            0x03, 0x00, 0x01, 0x00,                          // IEEE float, one channel
            0x80, 0x3e, 0x00, 0x00,                          // 16,000 samples a second
            0x00, 0xfa, 0x00, 0x00,                          // 64,000 bytes a second
            0x04, 0x00, 0x20, 0x00, 0x00, 0x00,              // 4 bytes a frame, 32 bits a sample, no extension
            0x66, 0x61, 0x63, 0x74, 0x04, 0x00, 0x00, 0x00,  // "fact", 4 bytes
            0x03, 0x00, 0x00, 0x00,                          // 3 samples
            0x64, 0x61, 0x74, 0x61, 0x0c, 0x00, 0x00, 0x00,  // "data", 12 bytes
        ]
        XCTAssertEqual(Array(TuningAudio.header(sampleCount: 3)), expected)
    }

    /// More than one copy chunk of audio comes out whole, in a WAV AVAudioFile reads, and the pass still gets its file as it was.
    func testKeepWritesAWAVOfTheSessionAndLeavesTheSessionFile() throws {
        let samples = (0..<300_000).map { Float($0 % 1_000) / 1_000 - 0.5 }
        let session = try sessionFile(samples)
        let before = try Data(contentsOf: session)
        let url = try TuningAudio.keep(session, sessionID: "session-1", in: kept)
        XCTAssertEqual(url, TuningAudio.url(sessionID: "session-1", in: kept))
        XCTAssertEqual(try Data(contentsOf: session), before, "The session file is only read")
        XCTAssertEqual(names(kept), ["session-1.wav"], "No half-written copy is left")

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.length, 300_000)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatFloat32)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 300_000))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        XCTAssertTrue(read == samples, "The WAV holds the session's samples")
        XCTAssertEqual(permissions(url), 0o600)
        XCTAssertEqual(permissions(kept), 0o700)
    }

    func testAFailedCopyLeavesNoHalfWrittenFile() throws {
        let session = try sessionFile([1, 2, 3])
        // A folder where the WAV goes makes the final rename fail after the copy is written.
        try FileManager.default.createDirectory(at: kept.appendingPathComponent("blocked.wav/inside"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try TuningAudio.keep(session, sessionID: "blocked", in: kept))
        XCTAssertEqual(names(kept), ["blocked.wav"])
        XCTAssertThrowsError(try TuningAudio.keep(directory.appendingPathComponent("missing.f32"), sessionID: "missing", in: kept))
        XCTAssertEqual(names(kept), ["blocked.wav"])
    }

    func testFilesPastThirtyDaysExpireAndOthersStay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func file(_ name: String, _ age: TimeInterval) -> TuningAudio.File { .init(name: name, written: now - age, bytes: 1) }
        let files = [
            file("fresh.wav", day),
            file("edge.wav", 30 * day),                 // exactly thirty days old: kept
            file("late.wav", 30 * day + 1),
            file("captions.srt", 90 * day),             // not written by Jot
            file("ahead.wav", -2 * day),                // the clock went back
        ]
        XCTAssertEqual(TuningAudio.expired(files, now: now).map(\.name), ["late.wav"])
    }

    /// A copy writes its .partial file as it goes, so one untouched for a day was left by a crash.
    func testHalfWrittenCopiesExpireAfterADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = [
            TuningAudio.File(name: "copying.wav.partial", written: now - 23 * 60 * 60, bytes: 1),
            TuningAudio.File(name: "crashed.wav.partial", written: now - day - 1, bytes: 1),
        ]
        XCTAssertEqual(TuningAudio.expired(files, now: now).map(\.name), ["crashed.wav.partial"])
        XCTAssertEqual(TuningAudio.summary(files), .init(count: 0, bytes: 0, oldest: nil), "jot status counts finished WAVs only")
    }

    func testPruneDeletesExpiredFilesAndNamesTheirSessions() throws {
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let now = Date()
        try write("old.wav", bytes: 4, written: now - 31 * day)
        try write("new.wav", bytes: 4, written: now - day)
        try write("crashed.wav.partial", bytes: 4, written: now - 40 * day)
        try write("notes.txt", bytes: 4, written: now - 90 * day)
        XCTAssertEqual(TuningAudio.prune(in: kept, now: now), ["crashed", "old"])
        XCTAssertEqual(names(kept), ["new.wav", "notes.txt"])
        XCTAssertEqual(TuningAudio.prune(in: directory.appendingPathComponent("missing"), now: now), [])
    }

    func testSummaryCountsKeptWAVs() throws {
        XCTAssertEqual(TuningAudio.summary(in: kept), .init(count: 0, bytes: 0, oldest: nil))
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = Date(timeIntervalSince1970: 1_790_086_400)
        try write("a.wav", bytes: 10, written: newer)
        try write("b.wav", bytes: 20, written: older)
        try write("c.wav.partial", bytes: 5, written: older - day)
        try write("notes.txt", bytes: 7, written: older - day)
        XCTAssertEqual(TuningAudio.summary(in: kept), .init(count: 2, bytes: 30, oldest: older))
    }
}
