import Foundation

/// Read from the existing store on a background executor. No second transcript database or inferred speaker identity.
public struct SuggestionContext: Sendable {
    public let rows: [Transcript]
    public let sources: [Source]
    public let sessionTitle: String?

    public init(rows: [Transcript], sessionTitle: String?) {
        self.rows = rows; self.sessionTitle = sessionTitle
        let date = ISO8601DateFormatter()
        sources = rows.map { row in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(row)) ?? Data()
            let revision = Int(ContentHash.sha256(data).prefix(12), radix: 16) ?? 1
            return Source(id: row.id, kind: row.mode == "dictation" ? "dictation" : "meeting-transcript",
                          role: row.mode == "dictation" ? "user" : "participant",
                          speaker: row.mode == "dictation" ? nil : (row.speakerLabel ?? "unlabeled speaker"),
                          origin: "jot", scope: Source.Scope(session: row.sessionID),
                          timestamp: date.string(from: row.startedAt.addingTimeInterval(row.startSeconds)),
                          revision: revision, status: .current, text: row.text)
        }
    }
    public func input(target: Target, association: ContextAssociation = .explicitRecentRequest) -> ScenarioInput {
        var input = ScenarioInput(target: target, sources: sources)
        input.association = association
        return input
    }
    public func attribution(selected: [Source]) -> String {
        var parts: [String] = []
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("Recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "Meeting ‘\($0)’" } ?? "Latest session")
        }
        return parts.joined(separator: " + ")
    }
}
