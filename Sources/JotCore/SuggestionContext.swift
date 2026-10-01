import Foundation

/// Speech from the suggestion window, read from the existing store on a background executor. No second transcript
/// database. Rows become sources the way a reader would take them:
/// - Consecutive ambient rows from one voice a moment apart are one turn, so a sentence recognized in three-second
///   pieces arrives whole, and ten minutes of speech fit the selector's twelve sources.
/// - An ambient row heard during a dictation hold repeats that dictation, so only the dictation is kept.
/// - The voice heard during the holds of a session is the user's: its other rows in that session are the user's words.
///   So is a voice the pass labeled You, or one within the People threshold of the learned user voice (`userSpeakers`).
/// - A named voice is that participant. Any other voice is unidentified, which the prompt says may be the user.
public struct SuggestionContext: Sendable {
    public let rows: [Transcript]
    public let sources: [SuggestionSource]
    public let sessionTitle: String?
    /// The rows each source was built from, by source id.
    private let members: [String: [Transcript]]
    /// Rows from one voice at most this far apart read as one turn.
    static let turnGap: TimeInterval = 1.5

    /// `userSpeakers`: session speakers whose pass voice is the user's, as `userSpeakerKey` names them.
    public init(rows: [Transcript], sessionTitle: String?, userSpeakers: Set<String> = []) {
        self.rows = rows; self.sessionTitle = sessionTitle
        let dictations = rows.filter { $0.mode == "dictation" }
        let (heard, heldSeconds) = Self.splitHolds(rows)
        let userVoice = heldSeconds.compactMapValues { voices in voices.max { $0.value < $1.value }?.key }
        var groups = dictations.map { [$0] }
        for row in heard.sorted(by: { Self.start($0) != Self.start($1) ? Self.start($0) < Self.start($1) : $0.id < $1.id }) {
            if let last = groups.last?.last, last.mode != "dictation", last.sessionID == row.sessionID,
               last.speakerID == row.speakerID, last.speakerLabel == row.speakerLabel,
               Self.start(row) - Self.end(last) <= Self.turnGap {
                groups[groups.count - 1].append(row)
            } else {
                groups.append([row])
            }
        }
        groups.sort { Self.start($0[0]) != Self.start($1[0]) ? Self.start($0[0]) < Self.start($1[0]) : $0[0].id < $1[0].id }
        let date = ISO8601DateFormatter()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        sources = groups.map { group in
            let first = group[0]
            let revision = Int(ContentHash.sha256((try? encoder.encode(group)) ?? Data()).prefix(12), radix: 16) ?? 1
            let role: String, speaker: String?
            if first.mode == "dictation" { role = "user"; speaker = nil }
            else if let voice = first.speakerID, userVoice[first.sessionID] == voice || first.speakerLabel == UserVoice.label
                        || userSpeakers.contains(Self.userSpeakerKey(session: first.sessionID, speaker: voice)) {
                role = "user"; speaker = first.speakerLabel == UserVoice.label ? nil : first.speakerLabel
            }
            else if let label = first.speakerLabel { role = "participant"; speaker = label }
            else { role = "unknown"; speaker = first.speakerID.map { $0.replacingOccurrences(of: "-", with: " ") } }
            return SuggestionSource(id: first.id, kind: first.mode == "dictation" ? "dictation" : "meeting-transcript",
                          role: role, speaker: speaker, origin: "jot", scope: SuggestionSource.Scope(session: first.sessionID),
                          timestamp: date.string(from: first.startedAt.addingTimeInterval(first.startSeconds)),
                          revision: revision, status: .current, text: group.map(\.text).joined(separator: " "))
        }
        members = Dictionary(uniqueKeysWithValues: groups.map { ($0[0].id, $0) })
    }

    /// The rows behind these sources: what must be unchanged when the suggestion is accepted.
    public func rows(for sources: [SuggestionSource]) -> [Transcript] { sources.flatMap { members[$0.id] ?? [] } }

    public func input(target: SuggestionTarget, association: ContextAssociation = .explicitRecentRequest) -> SuggestionRequest {
        var input = SuggestionRequest(target: target, sources: sources)
        input.association = association
        return input
    }

    /// Ambient rows mostly inside a dictation hold repeat the dictation, so they are set aside; per session, the seconds
    /// each voice spent inside holds is what they contribute.
    static func splitHolds(_ rows: [Transcript]) -> (heard: [Transcript], heldSeconds: [String: [String: Double]]) {
        let dictations = rows.filter { $0.mode == "dictation" }
        var heldSeconds: [String: [String: Double]] = [:]
        var heard: [Transcript] = []
        for row in rows where row.mode != "dictation" {
            let held = dictations.filter { $0.sessionID == row.sessionID }.reduce(0.0) { total, hold in
                total + max(0, min(Self.end(hold), Self.end(row)) - max(Self.start(hold), Self.start(row)))
            }
            guard held * 2 < max(Self.end(row) - Self.start(row), 0.01) else {
                if let voice = row.speakerID { heldSeconds[row.sessionID, default: [:]][voice, default: 0] += held }
                continue
            }
            heard.append(row)
        }
        return (heard, heldSeconds)
    }

    /// The voice heard most during each session's dictation holds, and for how long: the user's own voice. The speaker
    /// pass learns the user's voice from it once the session's rows carry the pass's speaker ids.
    public static func heldVoices(rows: [Transcript]) -> [String: (speakerID: String, heldSeconds: Double)] {
        splitHolds(rows).heldSeconds.compactMapValues { voices in voices.max { $0.value < $1.value }.map { ($0.key, $0.value) } }
    }

    public static func userSpeakerKey(session: String, speaker: String) -> String { session + "\u{0}" + speaker }

    private static func start(_ row: Transcript) -> TimeInterval { row.startedAt.timeIntervalSince1970 + row.startSeconds }
    private static func end(_ row: Transcript) -> TimeInterval { row.startedAt.timeIntervalSince1970 + row.endSeconds }
}
