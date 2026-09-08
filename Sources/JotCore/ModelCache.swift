import Foundation

/// One speech model Jot downloads the first time it loads.
public struct ModelDownload: Sendable, Identifiable, Equatable {
    public let name: String
    public let purpose: String
    public let bytes: Int64
    public var id: String { name }
    public init(name: String, purpose: String, bytes: Int64) {
        self.name = name; self.purpose = purpose; self.bytes = bytes
    }
}

/// The on-disk cache FluidAudio fills the first time Jot prepares models.
public enum ModelCache {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Measured from a completed first download on 2026-09-08 against the FluidAudio revision pinned in project.yml.
    public static let expected: [ModelDownload] = [
        ModelDownload(name: "Parakeet v3", purpose: "Turns speech into words", bytes: 483_257_242),
        ModelDownload(name: "Sortformer", purpose: "Separates who is speaking", bytes: 240_559_364),
        ModelDownload(name: "Silero", purpose: "Detects when speech starts and stops", bytes: 1_063_427)
    ]

    public static var expectedBytes: Int64 { expected.reduce(0) { $0 + $1.bytes } }

    /// Total size of every cached file. Zero when nothing has been downloaded.
    public static func bytesOnDisk(at root: URL? = nil) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root ?? directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    public static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = bytes < 1_000_000_000 ? [.useMB] : [.useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
