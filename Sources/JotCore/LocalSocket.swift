import Foundation
import Darwin

/// Bounded frames, same-user peer validation and macOS socket configuration shared
/// by the client and server. Neither caller owns these transport details.
enum LocalSocket {
    static let maxRequestBytes = 1_048_576
    static let maxResponseBytes = 4_194_304

    static func address(_ url: URL) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw LocalServiceError.invalid("Unix socket path exceeds macOS limit") }
        withUnsafeMutableBytes(of: &addr.sun_path) { target in target.copyBytes(from: bytes) }
        return addr
    }

    static func configure(_ fd: Int32, timeout: Int = 10) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func ownPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func connectSocket(_ fd: Int32, _ url: URL) throws -> Int32 {
        var addr = try address(url)
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func receiveLine(_ fd: Int32, limit: Int, timeout: TimeInterval = 10) throws -> Data {
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

    static func sendLine(_ data: Data, fd: Int32) throws {
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
}
