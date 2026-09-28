import Foundation

/// An advisory lock on Jot's directory, held for the life of the process that opened the store. Debug, worktree and
/// Xcode builds all share `~/Library/Application Support/Jot`, and opening an older-format database rebuilds the file;
/// with the lock, a second Jot launched while the installed app runs finds it held and leaves the database alone, so a
/// rebuild can never unlink the file under a running writer. `flock` locks the open file description, so a second lock
/// in the same process fails the same way, which the test relies on. Releasing the lock closes the descriptor.
public final class DirectoryLock {
    public enum Failure: Error, LocalizedError, Equatable {
        /// Another process holds the lock.
        case held(String)
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .held(let directory):
                return "Another Jot is already using \(directory). Quit it before opening this one; this Jot left the history untouched."
            case .unavailable(let message): return message
            }
        }
    }

    public static let fileName = "jot.lock"
    public let url: URL
    private let descriptor: Int32

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(Self.fileName)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable("Could not open \(url.path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.held(directory.path) }
            throw Failure.unavailable("Could not lock \(url.path): \(String(cString: strerror(code)))")
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
