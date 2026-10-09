import Foundation

/// Session audio kept to tune recognition while `keepTuningAudio` is on. Before the speaker pass reads and deletes a
/// session's file, a copy goes to `tuning-audio/<sessionID>.wav` in the Jot directory, as a 16 kHz mono 16-bit PCM WAV that
/// `jot lab` and other tools open directly. The folder is outside `audio/`, so the launch cleanup of stale session files
/// leaves it alone. At launch and each time a file is added, kept files more than 30 days old are deleted, then the oldest
/// while the rest total more than 10 GB.
public enum TuningAudio {
    /// One file in the folder: its name, when it was last written, and its size.
    struct File: Sendable, Equatable {
        let name: String
        let written: Date
        let bytes: Int
    }

    /// The kept WAVs, for `jot status`, and the limits pruning holds them to. `oldest` is left out when there are none.
    public struct Summary: Sendable, Equatable, Encodable {
        public let count: Int
        public let bytes: Int
        public let oldest: Date?
        public var limitBytes = TuningAudio.maximumBytes
        public var limitDays = Int(TuningAudio.maximumAge / (24 * 60 * 60))
    }

    /// What pruning deletes, oldest first: file names from `expired`, session ids from `prune`.
    public struct Pruned: Sendable, Equatable {
        /// WAVs more than 30 days old.
        public var old: [String] = []
        /// The oldest WAVs, while the rest total more than 10 GB.
        public var overLimit: [String] = []
        /// Copies a crash left half-written.
        public var unfinished: [String] = []
    }

    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    /// 10 GB, as Finder counts it: about 87 hours of 16-bit audio.
    static let maximumBytes = 10_000_000_000
    static let partialMaximumAge: TimeInterval = 24 * 60 * 60
    static let sampleRate: UInt32 = 16_000
    /// The header bytes the RIFF size counts: all 44 but the RIFF tag and the size itself.
    private static let headerBytesAfterRIFFSize: UInt32 = 36
    /// The most samples a WAV's 32-bit sizes can describe. A session file holds at most two hours, far fewer.
    static let maximumSamples = Int(UInt32.max - headerBytesAfterRIFFSize) / MemoryLayout<Int16>.size
    /// A copy reads a megabyte of the session file at a time, so a two-hour session never sits in memory whole.
    static let chunkBytes = 1 << 20

    public static var directory: URL { JotPaths.directory.appendingPathComponent("tuning-audio", isDirectory: true) }

    public static func url(sessionID: String, in directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent(sessionID + ".wav", isDirectory: false)
    }

    /// The 44-byte header of a mono 16 kHz 16-bit PCM WAV of `sampleCount` samples, little-endian.
    static func header(sampleCount: Int) -> Data {
        precondition(sampleCount >= 0 && sampleCount <= maximumSamples)
        let dataBytes = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: Array(value.utf8)) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(headerBytesAfterRIFFSize + dataBytes); text("WAVE")
        text("fmt "); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataBytes)
        return header
    }

    /// One Float32 sample as 16-bit PCM: clamped to -1...1 so a loud peak saturates rather than wraps, and a NaN is silence.
    static func pcm16(_ sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        return Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
    }

    /// Copies a finished session file, mono 16 kHz Float32 with no header as SessionAudioWriter writes it, into a 16-bit PCM
    /// WAV for `sessionID`, converting a chunk at a time. The copy is written as `<sessionID>.wav.partial` and renamed once
    /// complete, so a failure leaves no WAV. The session file is only read.
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
                    // Each chunk's buffers are released before the next is read.
                    try autoreleasepool {
                        guard let chunk = try input.read(upToCount: min(remaining, chunkBytes)), !chunk.isEmpty,
                              chunk.count % MemoryLayout<Float>.size == 0 else {
                            throw StoreError.database("Session audio ended before its copy was complete.")
                        }
                        let count = chunk.count / MemoryLayout<Float>.size
                        var converted = Data(count: count * MemoryLayout<Int16>.size)
                        chunk.withUnsafeBytes { floats in
                            converted.withUnsafeMutableBytes { pcm in
                                for index in 0..<count {
                                    let sample = floats.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                                    pcm.storeBytes(of: pcm16(sample).littleEndian, toByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)
                                }
                            }
                        }
                        try output.write(contentsOf: converted)
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

    /// The kept files to delete at `now`: WAVs written more than 30 days earlier, then the oldest of the rest while they total
    /// more than 10 GB, and copies a crash left half-written a day or more ago. Anything else in the folder is not Jot's and stays.
    static func expired(_ files: [File], now: Date) -> Pruned {
        var pruned = Pruned()
        var kept: [File] = []
        for file in files.sorted(by: { ($0.written, $0.name) < ($1.written, $1.name) }) {
            let age = now.timeIntervalSince(file.written)
            // A copy writes its .partial file as it goes, so one untouched for a day was left by a crash.
            if file.name.hasSuffix(".wav.partial") {
                if age > partialMaximumAge { pruned.unfinished.append(file.name) }
            } else if file.name.hasSuffix(".wav") {
                if age > maximumAge { pruned.old.append(file.name) } else { kept.append(file) }
            }
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for file in kept where total > maximumBytes {
            pruned.overLimit.append(file.name)
            total -= file.bytes
        }
        return pruned
    }

    /// Deletes what `expired` picks and returns the session ids it deleted, so each deletion is logged.
    @discardableResult
    public static func prune(in directory: URL = Self.directory, now: Date) -> Pruned {
        let expired = expired(files(in: directory), now: now)
        func delete(_ names: [String]) -> [String] {
            names.compactMap { name in
                guard (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil else { return nil }
                let wav = name.hasSuffix(".partial") ? String(name.dropLast(".partial".count)) : name
                return String(wav.dropLast(".wav".count))
            }
        }
        return Pruned(old: delete(expired.old), overLimit: delete(expired.overLimit), unfinished: delete(expired.unfinished))
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
