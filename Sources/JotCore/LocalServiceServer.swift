import Foundation
import Darwin

/// Bounded local IPC: eight clients, 1 MiB requests, 4 MiB responses, ten-second input deadline.
public final class LocalServiceServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data
    private let socketURL: URL
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients: Set<Int32> = []
    private var inode: ino_t?
    private var generation = UUID()

    public init(socketURL: URL = JotPaths.socketURL, handler: @escaping Handler) {
        self.socketURL = socketURL; self.handler = handler
    }
    deinit { stop() }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == -1 else { return }
        try preparePrivateDirectory(socketURL.deletingLastPathComponent())
        var info = stat()
        if lstat(socketURL.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw LocalServiceError.invalid("Refusing to replace a non-socket or foreign service path") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw LocalServiceError.unavailable("Could not probe existing socket") }
            LocalSocket.configure(probe, timeout: 1)
            let result: Int32
            do { result = try LocalSocket.connectSocket(probe, socketURL) } catch { close(probe); throw error }
            let savedErrno = errno; close(probe)
            guard result != 0 else { throw LocalServiceError.invalid("Another Jot service already owns this socket") }
            guard savedErrno == ECONNREFUSED else { throw LocalServiceError.invalid("Existing socket could not be safely identified as stale") }
            var current = stat()
            guard lstat(socketURL.path, &current) == 0, current.st_ino == info.st_ino, current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFSOCK else { throw LocalServiceError.invalid("Service socket changed while checking ownership") }
            guard unlink(socketURL.path) == 0 else { throw LocalServiceError.unavailable("Could not remove stale socket") }
        } else if errno != ENOENT { throw LocalServiceError.unavailable("Could not inspect local service socket") }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.unavailable("Could not create service socket") }
        LocalSocket.configure(fd)
        do {
            var addr = try LocalSocket.address(socketURL)
            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw LocalServiceError.unavailable("Could not bind service socket: \(String(cString: strerror(errno)))") }
            guard lstat(socketURL.path, &info) == 0 else { throw LocalServiceError.unavailable("Could not inspect bound socket") }
            inode = info.st_ino
            guard chmod(socketURL.path, 0o600) == 0, listen(fd, 8) == 0 else { throw LocalServiceError.unavailable("Could not secure or listen on service socket") }
            listener = fd; generation = UUID()
            let run = generation
            DispatchQueue(label: "Jot.local-service.accept", qos: .utility).async { [weak self] in self?.acceptConnections(fd, run: run) }
        } catch {
            close(fd); removeOwnedSocket(); throw error
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        generation = UUID()
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        removeOwnedSocket()
    }

    private func removeOwnedSocket() {
        var info = stat()
        if let inode, lstat(socketURL.path, &info) == 0, info.st_ino == inode, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(socketURL.path) }
        inode = nil
    }

    private func acceptConnections(_ fd: Int32, run: UUID) {
        while true {
            lock.lock(); let active = listener == fd && generation == run; lock.unlock()
            guard active else { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            LocalSocket.configure(client)
            lock.lock()
            let allowed = listener == fd && generation == run && clients.count < 8 && LocalSocket.ownPeer(client)
            if allowed { clients.insert(client) }
            lock.unlock()
            guard allowed else { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { lock.lock(); clients.remove(fd); close(fd); lock.unlock() }
        do {
            let request = try LocalSocket.receiveLine(fd, limit: LocalSocket.maxRequestBytes)
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any], object["method"] is String, object["params"] == nil || object["params"] is [String: Any] else { throw LocalServiceError.invalid("Expected JSON object with method and params") }
            let box = ResponseBox()
            let task = Task { [handler] in box.set(await handler(request)) }
            guard box.ready.wait(timeout: .now() + 600) == .success else { task.cancel(); throw LocalServiceError.unavailable("Service operation timed out") }
            let response = box.get()
            guard response.count <= LocalSocket.maxResponseBytes else { throw LocalServiceError.invalid("IPC response exceeds size limit; request fewer results") }
            try LocalSocket.sendLine(response, fd: fd)
        } catch {
            if let response = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]) { try? LocalSocket.sendLine(response, fd: fd) }
        }
    }
}
