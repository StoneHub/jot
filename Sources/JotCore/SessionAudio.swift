import Foundation

/// Where an ambient session's audio waits for the speaker pass. A file is named <sessionID>.f32 and holds mono 16 kHz Float32 samples with no header.
public enum SessionAudioPaths {
    public static var directory: URL { JotPaths.directory.appendingPathComponent("audio", isDirectory: true) }

    public static func url(sessionID: String, in directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent(sessionID + ".f32", isDirectory: false)
    }

    /// User-only, like the rest of the service data.
    public static func prepareDirectory(_ directory: URL = Self.directory) throws { try preparePrivateDirectory(directory) }

    /// Session ids of the files an earlier run left behind. Only the running session may have a file here.
    public static func staleSessionIDs(except sessionID: String, in directory: URL = Self.directory) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "f32" }.map { $0.deletingPathExtension().lastPathComponent }.filter { $0 != sessionID }.sorted()
    }
}
