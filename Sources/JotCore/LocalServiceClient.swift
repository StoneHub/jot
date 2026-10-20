import Foundation
import Darwin

/// One request per connection. Both ends validate the peer UID; no TCP listener exists.
public struct LocalServiceClient: Sendable {
    public let socketURL: URL
    public init(socketURL: URL = JotPaths.socketURL) { self.socketURL = socketURL }
    public func request(_ method: LocalMethod, params: [String: Any] = [:], timeout: Int? = nil) throws -> Data {
        try request(method: method.rawValue, params: params, timeout: timeout)
    }

    /// By wire name, for callers that relay a name rather than choose a method, such as `jot listen`'s injectable request.
    public func request(method: String, params: [String: Any] = [:], timeout: Int? = nil) throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params], options: [.sortedKeys])
        guard request.count <= LocalSocket.maxRequestBytes else { throw LocalServiceError.invalid("IPC request exceeds size limit") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.unavailable("Could not create local socket") }
        defer { close(fd) }
        // Starts wait for the models to load (a first load after an update compiles them); End meeting waits for the backlog.
        let timeout = timeout ?? (LocalMethod(rawValue: method)?.isLongRunning == true ? 600 : 30)
        LocalSocket.configure(fd, timeout: timeout)
        guard try LocalSocket.connectSocket(fd, socketURL) == 0 else { throw LocalServiceError.unavailable("Jot is not running. Open Jot.app, then retry. (\(String(cString: strerror(errno))))") }
        guard LocalSocket.ownPeer(fd) else { throw LocalServiceError.invalid("Service peer belongs to a different user") }
        try LocalSocket.sendLine(request, fd: fd)
        return try LocalSocket.receiveLine(fd, limit: LocalSocket.maxResponseBytes, timeout: TimeInterval(timeout))
    }
}
