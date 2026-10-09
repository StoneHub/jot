import Foundation
import JotCore

public struct AudioJob: Sendable {
    public let sessionID: String
    public let startedAt: Date
    public let offset: Double
    public let samples: [Float]
    public let ticket: UUID
    public var isFinal = false
    /// Cut while the dictation key was held, so a dictated "Okay" is saved even though it is only a filler.
    public var keepsFillers = false
    public var submittedUptime = ProcessInfo.processInfo.systemUptime

    public init(sessionID: String, startedAt: Date, offset: Double, samples: [Float], ticket: UUID, isFinal: Bool = false, keepsFillers: Bool = false) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.offset = offset
        self.samples = samples
        self.ticket = ticket
        self.isFinal = isFinal
        self.keepsFillers = keepsFillers
    }
}
