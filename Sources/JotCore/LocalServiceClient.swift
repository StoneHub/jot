import Foundation
import Darwin

/// One request per connection. Both ends validate the peer UID; no TCP listener exists.
public struct LocalServiceClient: Sendable {
    public let socketURL: URL
    public init(socketURL: URL = JotPaths.socketURL) { self.socketURL = socketURL }
    public func request(method: String, params: [String: Any] = [:], timeout: Int? = nil) throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params], options: [.sortedKeys])
        guard request.count <= LocalSocket.maxRequestBytes else { throw LocalServiceError.invalid("IPC request exceeds size limit") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.unavailable("Could not create local socket") }
        defer { close(fd) }
        let timeout = timeout ?? (["models.prepare", "speech.transcribe_file", "speech.meeting_end"].contains(method) ? 600 : 30)
        LocalSocket.configure(fd, timeout: timeout)
        guard try LocalSocket.connectSocket(fd, socketURL) == 0 else { throw LocalServiceError.unavailable("Jot is not running. Open Jot.app, then retry. (\(String(cString: strerror(errno))))") }
        guard LocalSocket.ownPeer(fd) else { throw LocalServiceError.invalid("Service peer belongs to a different user") }
        try LocalSocket.sendLine(request, fd: fd)
        return try LocalSocket.receiveLine(fd, limit: LocalSocket.maxResponseBytes, timeout: TimeInterval(timeout))
    }
}
