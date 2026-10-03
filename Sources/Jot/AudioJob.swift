import Foundation
import JotCore

struct AudioJob: Sendable {
    let sessionID: String
    let startedAt: Date
    let offset: Double
    let samples: [Float]
    let ticket: UUID
    var isFinal = false
    /// Cut while the dictation key was held, so a dictated "Okay" is saved even though it is only a filler.
    var keepsFillers = false
    var submittedUptime = ProcessInfo.processInfo.systemUptime
}
