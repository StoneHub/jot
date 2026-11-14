import Foundation

/// One request on Jot's socket: which program asked, and for what. Jot keeps a count per day, program and method
/// in the encrypted database, so `jot clients` can say which programs read history. Nothing in it leaves this Mac.
public struct ClientCall: Sendable, Equatable {
    public let pid: pid_t
    /// The caller's executable, or nil when the kernel could not say.
    public let executablePath: String?
    public let method: String

    public init(pid: pid_t, executablePath: String?, method: String) {
        self.pid = pid; self.executablePath = executablePath; self.method = method
    }
}

/// What one program called over a span of days.
public struct ClientCallSummary: Codable, Sendable, Equatable {
    public static let unknownPath = "(unknown)"
    /// How long calls are kept, and the most days `clients.list` reports.
    public static let retainedDays = 90
    public let path: String
    public let method: String
    public let count: Int
    public let firstDay: String
    public let lastAt: Date
}
