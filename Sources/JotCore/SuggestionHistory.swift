import Foundation
import SQLite3

/// One request's operational facts. There is deliberately no field, source, prompt or output text here.
public struct SuggestionHistoryEntry: Codable, Sendable, Equatable {
    public enum FieldRole: String, Codable, Sendable { case textArea, textField, comboBox, unknown }
    public enum Purpose: String, Codable, Sendable { case agentPrompt, textEntry, singleLine }
    public enum Plan: String, Codable, Sendable { case reply, continuation, draft, needsNotes }
    public enum Mode: String, Codable, Sendable { case reply, continuation, draft, none }
    public enum Outcome: String, Codable, Sendable {
        case requested, loading, ready, noSuggestion, unavailable, timedOut, blocked, failed
        case inserted, insertionUnverified, insertionCancelled
    }
    public enum Reason: String, Codable, Sendable {
        case noContext, needsNotes, refused, unsupportedField, unreadableField, contextUnreadable
        case modelAbstained, emptyOutput, rejectedOutput, mixedAbstainMarker, controlCharacters
        case multilineSingleLineField, multilineShellCommand, multipleParagraphs
        case copiesContext, unchanged, restatesHint, sourcesChanged, targetChanged
        case modelUnavailable, modelTimedOut, modelBusy, modelFailed
        case insertionUnverified, insertionCancelled, selectionUnavailable

        /// Convert only known internal result codes; never persist an arbitrary error or model string.
        public init(code: String) {
            switch code {
            case "no-context": self = .noContext
            case "needs-notes": self = .needsNotes
            case "refused": self = .refused
            case "unsupported-field": self = .unsupportedField
            case "unreadable-field": self = .unreadableField
            case "context-unreadable": self = .contextUnreadable
            case "model-abstained": self = .modelAbstained
            case "empty-output": self = .emptyOutput
            case "mixed-abstain-marker": self = .mixedAbstainMarker
            case "control-characters": self = .controlCharacters
            case "multiline-single-line-field": self = .multilineSingleLineField
            case "multiline-shell-command": self = .multilineShellCommand
            case "multiple-paragraphs": self = .multipleParagraphs
            case "copies-context": self = .copiesContext
            case "unchanged": self = .unchanged
            case "restates-hint": self = .restatesHint
            case "sources-changed": self = .sourcesChanged
            case "target-changed": self = .targetChanged
            case "model-unavailable": self = .modelUnavailable
            case "timed-out": self = .modelTimedOut
            case "blocked": self = .modelBusy
            case "model-failed": self = .modelFailed
            case "insertion-unverified": self = .insertionUnverified
            case "insertion-cancelled": self = .insertionCancelled
            case "selection-unavailable": self = .selectionUnavailable
            default: self = .rejectedOutput
            }
        }
    }
    public enum Action: String, Codable, Sendable {
        case acceptedVerified, acceptedUnverified, escape, typedOver, focusChanged
        case expired, sourcesChanged, settingsChanged, keyboardSourceChanged, newRequest, serviceStopped
    }
    public enum SourceKind: String, Codable, Sendable {
        case screenText, dictation, meetingTranscript, heardSpeech, agentMessage, pinnedSelection, other

        public init(_ source: Source) {
            switch source.kind {
            case "screen-text": self = .screenText
            case "dictation": self = .dictation
            case "meeting-transcript": self = .meetingTranscript
            case "heard-speech": self = .heardSpeech
            case "agent-message": self = .agentMessage
            case "pinned-selection": self = .pinnedSelection
            default: self = .other
            }
        }
    }
    public enum ExcludedKind: String, Codable, Sendable {
        case deleted, stale, duplicate, generatedNotIntent, unrelatedScope, otherConversation
        case unknownScope, overLimit, notInOracleContext

        public init(_ reason: ExclusionReason) {
            switch reason {
            case .deleted: self = .deleted
            case .stale: self = .stale
            case .duplicate: self = .duplicate
            case .generatedNotIntent: self = .generatedNotIntent
            case .unrelatedScope: self = .unrelatedScope
            case .otherConversation: self = .otherConversation
            case .unknownScope: self = .unknownScope
            case .overLimit: self = .overLimit
            case .notInOracleContext: self = .notInOracleContext
            }
        }
    }
    /// What became of the optional window image. Nil when the setting is off; never the image or anything it shows.
    public enum WindowImageOutcome: String, Codable, Sendable {
        case attached, noPermission, unsupported, noWindow, captureFailed, captureTimedOut
    }
    public struct SourceUsage: Codable, Sendable, Equatable {
        public let kind: SourceKind
        public let count: Int
        /// UTF-8 bytes of whole selected sources actually sent to the prompt.
        public let bytes: Int
        public init(kind: SourceKind, count: Int, bytes: Int) {
            self.kind = kind; self.count = count; self.bytes = bytes
        }
    }
    public struct ExcludedUsage: Codable, Sendable, Equatable {
        public let reason: ExcludedKind
        public let count: Int
        public init(reason: ExcludedKind, count: Int) { self.reason = reason; self.count = count }
    }

    public let id: UUID
    public let revision: Int
    public let startedAt: Date
    public let appBundleID: String?
    public let fieldRole: FieldRole
    public let purpose: Purpose
    public let plan: Plan
    public let mode: Mode
    public let beforeEndsSentence: Bool
    public let draftCharacters: Int
    public let selectionCharacters: Int
    public let selected: [SourceUsage]
    public let excluded: [ExcludedUsage]
    public let agentInput: AgentContext.MatchState
    public let templateID: String
    public let deadlineMilliseconds: Int?
    public let generationMilliseconds: Int?
    public let previewMilliseconds: Int?
    public let windowImage: WindowImageOutcome?
    /// Finding and capturing the window, whether or not an image came of it.
    public let windowImageMilliseconds: Int?
    public let outcome: Outcome
    public let reason: Reason?
    public let action: Action?
    /// Closed requests are never marked interrupted when the app next launches.
    public let complete: Bool

    public init(id: UUID, revision: Int, startedAt: Date, appBundleID: String?, fieldRole: FieldRole,
                purpose: Purpose, plan: Plan, mode: Mode, beforeEndsSentence: Bool,
                draftCharacters: Int, selectionCharacters: Int, selected: [SourceUsage] = [],
                excluded: [ExcludedUsage] = [], agentInput: AgentContext.MatchState = .noMessages,
                deadlineMilliseconds: Int? = nil,
                generationMilliseconds: Int? = nil, previewMilliseconds: Int? = nil,
                windowImage: WindowImageOutcome? = nil, windowImageMilliseconds: Int? = nil,
                outcome: Outcome = .requested, reason: Reason? = nil, action: Action? = nil,
                complete: Bool = false) {
        self.id = id; self.revision = revision; self.startedAt = startedAt
        self.appBundleID = appBundleID; self.fieldRole = fieldRole; self.purpose = purpose
        self.plan = plan; self.mode = mode; self.beforeEndsSentence = beforeEndsSentence
        self.draftCharacters = draftCharacters; self.selectionCharacters = selectionCharacters
        self.selected = selected; self.excluded = excluded; self.agentInput = agentInput
        self.templateID = windowImage == .attached ? SuggestionPrompt.windowImageTemplateID : SuggestionPrompt.templateID
        self.deadlineMilliseconds = deadlineMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.previewMilliseconds = previewMilliseconds
        self.windowImage = windowImage; self.windowImageMilliseconds = windowImageMilliseconds
        self.outcome = outcome; self.reason = reason; self.action = action; self.complete = complete
    }

    public static func usage(_ selection: SourceSelection) -> (selected: [SourceUsage], excluded: [ExcludedUsage]) {
        usage(selected: selection.selected, excluded: selection.excluded)
    }

    public static func usage(selected: [Source], excluded: [SourceSelection.Exclusion]) ->
        (selected: [SourceUsage], excluded: [ExcludedUsage]) {
        var sources: [SourceKind: (count: Int, bytes: Int)] = [:]
        for source in selected {
            let kind = SourceKind(source)
            let previous = sources[kind] ?? (0, 0)
            sources[kind] = (previous.count + 1, previous.bytes + source.text.utf8.count)
        }
        var exclusionCounts: [ExcludedKind: Int] = [:]
        for source in excluded { exclusionCounts[ExcludedKind(source.reason), default: 0] += 1 }
        return (sources.map { SourceUsage(kind: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
                    .sorted { $0.kind.rawValue < $1.kind.rawValue },
                exclusionCounts.map { ExcludedUsage(reason: $0.key, count: $0.value) }
                    .sorted { $0.reason.rawValue < $1.reason.rawValue })
    }

    /// Bundle identifiers are operational metadata; a window title or field value never qualifies.
    public static func sanitizedBundleID(_ value: String) -> String? {
        guard value.contains("."), value.utf8.count <= 128,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return nil }
        return value
    }

    func validate() throws {
        if let appBundleID {
            guard Self.sanitizedBundleID(appBundleID) != nil else {
                throw StoreError.invalid("Suggestion app identity is invalid")
            }
        }
        guard revision >= 0, draftCharacters >= 0, draftCharacters <= 1_000_000,
              selectionCharacters >= 0, selectionCharacters <= draftCharacters,
              selected.count <= 12, excluded.count <= 9,
              selected.allSatisfy({ $0.count >= 0 && $0.count <= 12 && $0.bytes >= 0 && $0.bytes <= 6_000 }),
              selected.reduce(0, { $0 + $1.count }) <= 12,
              selected.reduce(0, { $0 + $1.bytes }) <= 6_000,
              excluded.allSatisfy({ $0.count >= 0 && $0.count <= 1_000 }),
              [deadlineMilliseconds, generationMilliseconds, previewMilliseconds, windowImageMilliseconds]
                .allSatisfy({ $0 == nil || (0...60_000).contains($0!) }) else {
            throw StoreError.invalid("Suggestion diagnostics exceed their bounds")
        }
    }
}

/// Adds a flag when a prior run ended before recording the request's final action.
public struct SavedSuggestionInteraction: Codable, Sendable, Equatable {
    public let entry: SuggestionHistoryEntry
    public let interrupted: Bool
}

/// Owns one small table in the existing transcript database. Actor isolation keeps writes off the UI actor.
public actor SuggestionHistory {
    public static let maximumRows = 200
    public static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private let db: SQLiteConnection

    public init(sharing store: TranscriptStore) throws {
        db = try SQLiteConnection(url: store.databaseURL)
        try db.locked {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS suggestion_interactions (
                    id TEXT PRIMARY KEY, started_at REAL NOT NULL, revision INTEGER NOT NULL,
                    complete INTEGER NOT NULL, interrupted INTEGER NOT NULL DEFAULT 0,
                    payload BLOB NOT NULL CHECK(length(payload) <= 4096));
                CREATE INDEX IF NOT EXISTS suggestion_interactions_time
                    ON suggestion_interactions(started_at DESC);
                """)
            // Any unfinished card from the previous process can no longer be accepted.
            try db.execute("UPDATE suggestion_interactions SET interrupted=1 WHERE complete=0")
            try Self.prune(db, now: Date())
        }
    }

    public func save(_ entry: SuggestionHistoryEntry, now: Date = Date()) throws {
        try entry.validate()
        let payload = try JSONEncoder().encode(entry)
        guard payload.count <= 4096 else { throw StoreError.invalid("Suggestion diagnostics exceed 4 KiB") }
        try db.locked {
            try db.transaction {
                let stmt = try db.prepare("""
                    INSERT INTO suggestion_interactions(id,started_at,revision,complete,interrupted,payload)
                    VALUES(?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET
                    started_at=excluded.started_at, revision=excluded.revision,
                    complete=excluded.complete, payload=excluded.payload
                    WHERE excluded.revision > suggestion_interactions.revision
                    """)
                defer { sqlite3_finalize(stmt) }
                db.bind(entry.id.uuidString, to: 1, in: stmt)
                sqlite3_bind_double(stmt, 2, entry.startedAt.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, Int64(entry.revision))
                sqlite3_bind_int(stmt, 4, entry.complete ? 1 : 0)
                db.bind(payload, to: 5, in: stmt)
                try db.finish(stmt)
                try Self.prune(db, now: now)
            }
        }
    }

    public func recent(limit: Int = 20, now: Date = Date()) throws -> [SavedSuggestionInteraction] {
        guard (1...Self.maximumRows).contains(limit) else { throw StoreError.invalid("Suggestion limit must be 1...200") }
        return try db.locked {
            try Self.prune(db, now: now)
            let stmt = try db.prepare("SELECT payload,interrupted FROM suggestion_interactions ORDER BY started_at DESC,id DESC LIMIT ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [SavedSuggestionInteraction] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw db.error() }
                let entry = try JSONDecoder().decode(SuggestionHistoryEntry.self, from: db.blob(stmt, 0))
                rows.append(SavedSuggestionInteraction(entry: entry, interrupted: sqlite3_column_int(stmt, 1) != 0))
            }
            return rows
        }
    }

    private static func prune(_ db: SQLiteConnection, now: Date) throws {
        try db.execute("DELETE FROM suggestion_interactions WHERE started_at < \(now.addingTimeInterval(-maximumAge).timeIntervalSince1970)")
        try db.execute("""
            DELETE FROM suggestion_interactions WHERE id NOT IN
                (SELECT id FROM suggestion_interactions ORDER BY started_at DESC,id DESC LIMIT \(maximumRows))
            """)
    }
}
