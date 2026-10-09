import Foundation

/// Session audio kept to tune recognition while `keepTuningAudio` is on. Before the speaker pass reads and deletes a
/// session's file, a copy goes to `tuning-audio/<sessionID>.wav` in the Jot directory, as a 16 kHz mono 32-bit float WAV that
/// `jot lab` and other tools open directly. The folder is outside `audio/`, so the launch cleanup of stale session files
/// leaves it alone. A kept file is deleted once it is more than 30 days old, at launch and each time a file is added.
public enum TuningAudio {
    /// One file in the folder: its name, when it was last written, and its size.
    struct File: Sendable, Equatable {
        let name: String
        let written: Date
        let bytes: Int
    }

    /// The kept WAVs, for `jot status`. `oldest` is left out when there are none.
    public struct Summary: Sendable, Equatable, Encodable {
        public let count: Int
        public let bytes: Int
        public let oldest: Date?
    }

    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let sampleRate: UInt32 = 16_000
    /// The header bytes the RIFF size counts: all 58 but the RIFF tag and the size itself.
    private static let headerBytesAfterRIFFSize: UInt32 = 50
    /// The most samples a WAV's 32-bit sizes can describe. A session file holds at most two hours, far fewer.
    static let maximumSamples = Int(UInt32.max - headerBytesAfterRIFFSize) / MemoryLayout<Float>.size
    /// A copy reads and writes a megabyte at a time, so a two-hour session never sits in memory whole.
    static let chunkBytes = 1 << 20

    public static var directory: URL { JotPaths.directory.appendingPathComponent("tuning-audio", isDirectory: true) }

    public static func url(sessionID: String, in directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent(sessionID + ".wav", isDirectory: false)
    }

    /// The header of a mono 16 kHz 32-bit float WAV of `sampleCount` samples, little-endian. Float is not PCM, so the fmt chunk
    /// is format 3 with its empty 2-byte extension and a fact chunk gives the sample count, as the WAVE format asks of non-PCM data.
    static func header(sampleCount: Int) -> Data {
        precondition(sampleCount >= 0 && sampleCount <= maximumSamples)
        let dataBytes = UInt32(sampleCount * MemoryLayout<Float>.size)
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: Array(value.utf8)) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(headerBytesAfterRIFFSize + dataBytes); text("WAVE")
        text("fmt "); u32(18)
        u16(3); u16(1); u32(sampleRate); u32(sampleRate * 4); u16(4); u16(32); u16(0)
        text("fact"); u32(4); u32(UInt32(sampleCount))
        text("data"); u32(dataBytes)
        return header
    }

    /// Copies a finished session file, mono 16 kHz Float32 with no header as SessionAudioWriter writes it, into the WAV for
    /// `sessionID`. The Mac is little-endian like WAV, so the samples go across byte for byte. The copy is written as
    /// `<sessionID>.wav.partial` and renamed once complete, so a failure leaves no WAV. The session file is only read.
    @discardableResult
    public static func keep(_ sessionFile: URL, sessionID: String, in directory: URL = Self.directory) throws -> URL {
        let input = try FileHandle(forReadingFrom: sessionFile)
        defer { try? input.close() }
        let sampleCount = Int(try input.seekToEnd()) / MemoryLayout<Float>.size
        guard sampleCount <= maximumSamples else { throw StoreError.invalid("Session audio is too long for a WAV file.") }
        try input.seek(toOffset: 0)
        // User-only, like the rest of the service data.
        try preparePrivateDirectory(directory)
        let target = url(sessionID: sessionID, in: directory)
        let partial = target.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: header(sampleCount: sampleCount),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.database("Could not create the tuning audio file.")
        }
        do {
            let output = try FileHandle(forWritingTo: partial)
            do {
                try output.seekToEnd()
                var remaining = sampleCount * MemoryLayout<Float>.size
                while remaining > 0 {
                    // Each chunk's buffer is released before the next is read.
                    try autoreleasepool {
                        guard let chunk = try input.read(upToCount: min(remaining, chunkBytes)), !chunk.isEmpty else {
                            throw StoreError.database("Session audio ended before its copy was complete.")
                        }
                        try output.write(contentsOf: chunk)
                        remaining -= chunk.count
                    }
                }
                try output.close()
            } catch { try? output.close(); throw error }
            guard rename(partial.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// The kept files to delete at `now`: WAVs, and copies a crash left half-written, written more than 30 days earlier.
    /// Anything else in the folder is not Jot's and stays.
    static func expired(_ files: [File], now: Date) -> [File] {
        files.filter { ($0.name.hasSuffix(".wav") || $0.name.hasSuffix(".wav.partial")) && now.timeIntervalSince($0.written) > maximumAge }
    }

    /// Deletes the kept files more than 30 days old and returns their session ids, so each deletion is logged.
    @discardableResult
    public static func prune(in directory: URL = Self.directory, now: Date) -> [String] {
        expired(files(in: directory), now: now).compactMap { file in
            guard (try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.name))) != nil else { return nil }
            let wav = file.name.hasSuffix(".partial") ? String(file.name.dropLast(".partial".count)) : file.name
            return String(wav.dropLast(".wav".count))
        }.sorted()
    }

    static func summary(_ files: [File]) -> Summary {
        let kept = files.filter { $0.name.hasSuffix(".wav") }
        return Summary(count: kept.count, bytes: kept.reduce(0) { $0 + $1.bytes }, oldest: kept.map(\.written).min())
    }

    /// How many WAVs are kept, their size and the oldest one's date. Reads the folder.
    public static func summary(in directory: URL = Self.directory) -> Summary { summary(files(in: directory)) }

    /// The regular files in the folder; none when it does not exist.
    static func files(in directory: URL) -> [File] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let written = values.contentModificationDate else { return nil }
            return File(name: url.lastPathComponent, written: written, bytes: values.fileSize ?? 0)
        }
    }
}
