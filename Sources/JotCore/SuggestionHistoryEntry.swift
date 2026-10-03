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

        public init(_ source: SuggestionSource) {
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

    public static func usage(selected: [SuggestionSource], excluded: [SourceSelection.Exclusion]) ->
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
