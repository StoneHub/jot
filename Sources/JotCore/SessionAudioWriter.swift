import Foundation

/// One session file's ordered writes. Admission and queued execution have separate owners:
/// a short lock orders submissions, while a utility queue owns the handle and file bytes.
public final class SessionAudioWriter: @unchecked Sendable {
    public struct Outcome: Sendable {
        public let bytes: Int
        public let truncated: Bool
    }
    public enum Failure: Error, LocalizedError {
        case backlog
        public var errorDescription: String? {
            "Session audio writes fell behind; offline speaker audio is unavailable. Recognized speech was kept."
        }
    }
    /// Eight seconds of mono 16 kHz Float32, including the currently writing packet.
    public static let defaultPendingByteLimit = 512_000
    public static let defaultPendingPacketLimit = 40
    private let url: URL
    private let byteLimit: Int
    private let pendingByteLimit: Int
    private let maximumPendingPackets: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Only accessed while holding lock; the queue also uses the lock for admission state.
    private var pendingBytes = 0
    private var pendingPackets = 0
    private var acceptedBytes = 0
    private var closed = false
    private var discarded = false
    private var truncated = false
    private var failure: Error?
    // Only accessed by queue.
    private var handle: FileHandle?
    private var writtenBytes = 0

    public var bufferedBytes: Int { lock.withLock { pendingBytes } }
    public var pendingPacketCount: Int { lock.withLock { pendingPackets } }

    public convenience init(url: URL, byteLimit: Int,
                            pendingByteLimit: Int = defaultPendingByteLimit,
                            maximumPendingPackets: Int = defaultPendingPacketLimit) {
        self.init(url: url, byteLimit: byteLimit, pendingByteLimit: pendingByteLimit,
                  maximumPendingPackets: maximumPendingPackets,
                  queue: DispatchQueue(label: "space.jot.session-audio", qos: .utility))
    }

    /// An injectable concrete queue lets checks hold the writer without changing capture.
    init(url: URL, byteLimit: Int, pendingByteLimit: Int, maximumPendingPackets: Int, queue: DispatchQueue) {
        precondition(byteLimit >= 0 && byteLimit % MemoryLayout<Float>.size == 0)
        precondition(pendingByteLimit > 0 && maximumPendingPackets > 0)
        self.url = url; self.byteLimit = byteLimit; self.pendingByteLimit = pendingByteLimit
        self.maximumPendingPackets = maximumPendingPackets; self.queue = queue
    }

    public func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard let count = reserve(sampleCount: samples.count) else { return }
        let retained = count == samples.count ? samples : Array(samples.prefix(count))
        queue.async { self.writePending(bytes: count * MemoryLayout<Float>.size) {
            retained.withUnsafeBufferPointer { Data(buffer: $0) }
        } }
    }

    public func appendSilence(samples: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let count = reserve(sampleCount: samples) else { return }
        let bytes = count * MemoryLayout<Float>.size
        queue.async { self.writePending(bytes: bytes) { Data(count: bytes) } }
    }

    /// Caller holds lock through enqueue, so finish/discard cannot overtake an admitted packet.
    private func reserve(sampleCount: Int) -> Int? {
        guard sampleCount > 0, !closed, !discarded, failure == nil else { return nil }
        let room = (byteLimit - acceptedBytes) / MemoryLayout<Float>.size
        let count = min(sampleCount, room)
        let bytes = count * MemoryLayout<Float>.size
        if count < sampleCount { truncated = true; closed = true }
        guard count > 0 else { return nil }
        guard bytes <= pendingByteLimit - pendingBytes, pendingPackets < maximumPendingPackets else {
            failure = Failure.backlog; closed = true
            // Already queued packets see the failure before allocating Data; any in-flight
            // write finishes before this removal. Never offer a file with a skipped interval.
            queue.async { self.remove() }
            return nil
        }
        acceptedBytes += bytes; pendingBytes += bytes; pendingPackets += 1
        return count
    }

    private func writePending(bytes: Int, data: () -> Data) {
        defer { lock.withLock { pendingBytes -= bytes; pendingPackets -= 1 } }
        guard lock.withLock({ !discarded && failure == nil }) else { return }
        do {
            if handle == nil {
                try SessionAudioPaths.prepareDirectory(url.deletingLastPathComponent())
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw StoreError.database("Could not create the session audio file.")
                }
                handle = try FileHandle(forWritingTo: url)
            }
            let packet = data()
            try handle?.write(contentsOf: packet)
            writtenBytes += packet.count
        } catch {
            lock.withLock { if failure == nil { failure = error }; closed = true }
            remove()
        }
    }

    /// Finishes admitted writes even when the waiter is cancelled. Appending after this barrier is refused.
    public func finish() async throws -> Outcome? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            closed = true
            queue.async {
                try? self.handle?.close(); self.handle = nil
                let state = self.lock.withLock { (self.failure, self.discarded, self.truncated) }
                if let failure = state.0 { self.remove(); continuation.resume(throwing: failure); return }
                guard !state.1, self.writtenBytes > 0 else { self.remove(); continuation.resume(returning: nil); return }
                continuation.resume(returning: Outcome(bytes: self.writtenBytes, truncated: state.2))
            }
        }
    }

    /// Closes admission immediately; queued packets release their reservations without making a new file.
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        guard !discarded else { return }
        discarded = true; closed = true
        queue.async { self.remove() }
    }

    private func remove() {
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
