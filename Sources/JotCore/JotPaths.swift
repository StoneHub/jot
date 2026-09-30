import Foundation

public enum JotPaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jot", isDirectory: true)
    }
    public static var socketURL: URL { directory.appendingPathComponent("service.sock") }
}
