import Foundation
import Darwin

public enum LocalServiceError: Error, LocalizedError {
    case unavailable(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message), .invalid(let message): return message }
    }
}

private let maxRequestBytes = 1_048_576
private let maxResponseBytes = 4_194_304

private func address(_ url: URL) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(url.path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw LocalServiceError.invalid("Unix socket path exceeds macOS limit") }
    withUnsafeMutableBytes(of: &addr.sun_path) { target in target.copyBytes(from: bytes) }
    return addr
}

private func configure(_ fd: Int32, timeout: Int = 10) {
    var value: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    var interval = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

private func ownPeer(_ fd: Int32) -> Bool {
    var uid: uid_t = 0; var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
}

private func connectSocket(_ fd: Int32, _ url: URL) throws -> Int32 {
    var addr = try address(url)
    return withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func receiveLine(_ fd: Int32, limit: Int, timeout: TimeInterval = 10) throws -> Data {
    var result = Data(); var chunk = [UInt8](repeating: 0, count: 8192)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw LocalServiceError.unavailable("Service frame timed out") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max))))
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw LocalServiceError.unavailable("Service frame timed out") }
        let count = recv(fd, &chunk, chunk.count, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw LocalServiceError.unavailable("Service connection closed or timed out") }
        let bytes = chunk.prefix(count)
        if let newline = bytes.firstIndex(of: 10) {
            guard result.count + newline <= limit else { throw LocalServiceError.invalid("IPC frame exceeds size limit") }
            result.append(contentsOf: bytes.prefix(newline))
            return result
        }
        guard result.count + count <= limit else { throw LocalServiceError.invalid("IPC frame exceeds size limit") }
        result.append(contentsOf: bytes)
    }
}

private func sendLine(_ data: Data, fd: Int32) throws {
    var frame = data; frame.append(10)
    try frame.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LocalServiceError.unavailable("Could not write service response") }
            offset += count
        }
    }
}

/// One request per connection. Both ends validate the peer UID; no TCP listener exists.
public struct LocalServiceClient: Sendable {
    public let socketURL: URL
    public init(socketURL: URL = JotPaths.socketURL) { self.socketURL = socketURL }
    public func request(method: String, params: [String: Any] = [:]) throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params], options: [.sortedKeys])
        guard request.count <= maxRequestBytes else { throw LocalServiceError.invalid("IPC request exceeds size limit") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.unavailable("Could not create local socket") }
        defer { close(fd) }
        let timeout = ["models.prepare", "speech.transcribe_file"].contains(method) ? 600 : 30
        configure(fd, timeout: timeout)
        guard try connectSocket(fd, socketURL) == 0 else { throw LocalServiceError.unavailable("Jot is not running. Open Jot.app, then retry. (\(String(cString: strerror(errno))))") }
        guard ownPeer(fd) else { throw LocalServiceError.invalid("Service peer belongs to a different user") }
        try sendLine(request, fd: fd)
        return try receiveLine(fd, limit: maxResponseBytes, timeout: TimeInterval(timeout))
    }
}

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
            configure(probe, timeout: 1)
            let result: Int32
            do { result = try connectSocket(probe, socketURL) } catch { close(probe); throw error }
            let savedErrno = errno; close(probe)
            guard result != 0 else { throw LocalServiceError.invalid("Another Jot service already owns this socket") }
            guard savedErrno == ECONNREFUSED else { throw LocalServiceError.invalid("Existing socket could not be safely identified as stale") }
            var current = stat()
            guard lstat(socketURL.path, &current) == 0, current.st_ino == info.st_ino, current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFSOCK else { throw LocalServiceError.invalid("Service socket changed while checking ownership") }
            guard unlink(socketURL.path) == 0 else { throw LocalServiceError.unavailable("Could not remove stale socket") }
        } else if errno != ENOENT { throw LocalServiceError.unavailable("Could not inspect local service socket") }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.unavailable("Could not create service socket") }
        configure(fd)
        do {
            var addr = try address(socketURL)
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
            configure(client)
            lock.lock()
            let allowed = listener == fd && generation == run && clients.count < 8 && ownPeer(client)
            if allowed { clients.insert(client) }
            lock.unlock()
            guard allowed else { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { lock.lock(); clients.remove(fd); close(fd); lock.unlock() }
        do {
            let request = try receiveLine(fd, limit: maxRequestBytes)
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any], object["method"] is String, object["params"] == nil || object["params"] is [String: Any] else { throw LocalServiceError.invalid("Expected JSON object with method and params") }
            let box = ResponseBox()
            let task = Task { [handler] in box.set(await handler(request)) }
            guard box.ready.wait(timeout: .now() + 600) == .success else { task.cancel(); throw LocalServiceError.unavailable("Service operation timed out") }
            let response = box.get()
            guard response.count <= maxResponseBytes else { throw LocalServiceError.invalid("IPC response exceeds size limit; request fewer results") }
            try sendLine(response, fd: fd)
        } catch {
            if let response = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]) { try? sendLine(response, fd: fd) }
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock(); ready.signal() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
