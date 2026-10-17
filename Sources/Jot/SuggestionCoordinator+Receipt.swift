import ApplicationServices
import Foundation
import JotCore

extension SuggestionCoordinator {
    /// What one request recorded for suggestion history: roles, counts, timings and outcomes, never field, screen or
    /// output text.
    struct Receipt {
        let id = UUID()
        let startedAt = Date()
        var revision = 0
        var appBundleID: String?
        var fieldRole: SuggestionHistoryEntry.FieldRole = .unknown
        var purpose: SuggestionHistoryEntry.Purpose = .textEntry
        var plan: SuggestionHistoryEntry.Plan = .needsNotes
        var mode: SuggestionHistoryEntry.Mode = .none
        var beforeEndsSentence = true
        var draftCharacters = 0
        var selectionCharacters = 0
        var selected: [SuggestionHistoryEntry.SourceUsage] = []
        var excluded: [SuggestionHistoryEntry.ExcludedUsage] = []
        var agentInput: AgentContext.MatchState = .noMessages
        var deadlineMilliseconds: Int?
        var generationMilliseconds: Int?
        var previewMilliseconds: Int?
        var windowImage: SuggestionHistoryEntry.WindowImageOutcome?
        var windowImageMilliseconds: Int?
        var generationStartedAt: Date?
        var outcome: SuggestionHistoryEntry.Outcome = .requested
        var reason: SuggestionHistoryEntry.Reason?
        var action: SuggestionHistoryEntry.Action?
        var complete = false

        func entry() -> SuggestionHistoryEntry {
            SuggestionHistoryEntry(id: id, revision: revision, startedAt: startedAt,
                appBundleID: appBundleID, fieldRole: fieldRole, purpose: purpose, plan: plan, mode: mode,
                beforeEndsSentence: beforeEndsSentence, draftCharacters: draftCharacters,
                selectionCharacters: selectionCharacters, selected: selected, excluded: excluded,
                agentInput: agentInput, deadlineMilliseconds: deadlineMilliseconds,
                generationMilliseconds: generationMilliseconds, previewMilliseconds: previewMilliseconds,
                windowImage: windowImage, windowImageMilliseconds: windowImageMilliseconds,
                outcome: outcome, reason: reason, action: action, complete: complete)
        }
        /// The field a request reads, before any context. Its role, purpose and sizes; never its text.
        mutating func describe(_ field: DictationInput.SuggestionField) {
            appBundleID = SuggestionHistoryEntry.sanitizedBundleID(field.bundleID)
            switch field.role {
            case kAXTextAreaRole: fieldRole = .textArea
            case kAXTextFieldRole: fieldRole = .textField
            case kAXComboBoxRole: fieldRole = .comboBox
            default: fieldRole = .unknown
            }
            purpose = field.role != kAXTextAreaRole ? .singleLine
                : field.bundleID == "com.openai.codex" ? .agentPrompt : .textEntry
            draftCharacters = (field.draft.value as NSString).length
            selectionCharacters = field.draft.length
            beforeEndsSentence = SuggestionPrompt.endsSentence(field.draft.before)
        }

        mutating func record(plan: SuggestionPlan, mode: SuggestionMode, before: String) {
            switch plan {
            case .reply: self.plan = .reply
            case .continuation: self.plan = .continuation
            case .draft: self.plan = .draft
            case .needsNotes: self.plan = .needsNotes
            }
            switch mode {
            case .reply: self.mode = .reply
            case .continuation: self.mode = .continuation
            case .draft: self.mode = .draft
            }
            beforeEndsSentence = SuggestionPrompt.endsSentence(before)
        }

        /// The selector's usage, plus the speech the heard-speech addition replaced or dropped, sorted by reason.
        mutating func record(_ usage: (selected: [SuggestionHistoryEntry.SourceUsage], excluded: [SuggestionHistoryEntry.ExcludedUsage]),
                             addition: HeardSpeech.Addition) {
            selected = usage.selected
            excluded = usage.excluded
            addExcluded(.duplicate, count: addition.duplicateSpeechCount)
            addExcluded(.overLimit, count: addition.overLimitSpeechCount)
            excluded.sort { $0.reason.rawValue < $1.reason.rawValue }
        }

        private mutating func addExcluded(_ reason: SuggestionHistoryEntry.ExcludedKind, count: Int) {
            guard count > 0 else { return }
            if let existing = excluded.firstIndex(where: { $0.reason == reason }) {
                let prior = excluded.remove(at: existing)
                excluded.append(.init(reason: reason, count: prior.count + count))
            } else { excluded.append(.init(reason: reason, count: count)) }
        }
    }
}
