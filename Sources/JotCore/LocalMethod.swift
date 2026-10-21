import Foundation

/// Every method Jot's local socket answers. The raw values are the wire names that the jot CLI, its MCP server and
/// the jot-vorssaint helper send. The app switches over this enum, so a method added here must be handled there.
public enum LocalMethod: String, CaseIterable, Sendable {
    case speechControls = "speech.controls"
    case speechStatus = "speech.status"
    case speechDiagnostics = "speech.diagnostics"
    case speechStart = "speech.start"
    case speechPause = "speech.pause"
    case speechResume = "speech.resume"
    case speechMeetingStart = "speech.meeting_start"
    case speechMeetingEnd = "speech.meeting_end"
    case speechTranscribeFile = "speech.transcribe_file"
    case activityReport = "activity.report"
    case modelsPrepare = "models.prepare"
    case modelsUnload = "models.unload"
    case modelsCheck = "models.check"
    case sessionsTitle = "sessions.title"
    case sessionsNotes = "sessions.notes"
    case settingsGet = "settings.get"
    case settingsSet = "settings.set"
    case settingsReset = "settings.reset"
    case transcriptsClear = "transcripts.clear"
    case transcriptsDeleteSession = "transcripts.delete_session"
    case transcriptsSearch = "transcripts.search"
    case transcriptsRecent = "transcripts.recent"
    case transcriptsEvents = "transcripts.events"
    case transcriptsSessions = "transcripts.sessions"
    case transcriptsSince = "transcripts.since"
    case transcriptsWait = "transcripts.wait"
    case transcriptsRead = "transcripts.read"
    case transcriptsExport = "transcripts.export"
    case suggestionsRecent = "suggestions.recent"
    case contextAdd = "context.add"
    case contextHook = "context.hook"
    case contextClear = "context.clear"
    case peopleList = "people.list"
    case peopleForget = "people.forget"
    /// The older name for `people.forget`, still answered for scripts that use it.
    case peopleDelete = "people.delete"
    case speakersLabel = "speakers.label"
    case vocabularyList = "vocabulary.list"
    case vocabularySave = "vocabulary.save"
    case vocabularyRemove = "vocabulary.remove"

    /// Methods that can wait on a model download or load, a file's recognition, a meeting's last speech, new transcript changes or session notes, so clients allow them longer.
    public var isLongRunning: Bool { [.modelsPrepare, .speechTranscribeFile, .speechStart, .speechMeetingStart, .speechMeetingEnd, .transcriptsWait, .sessionsNotes].contains(self) }
}
