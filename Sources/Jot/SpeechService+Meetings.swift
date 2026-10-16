import AppKit
import Foundation
import JotCore
import JotEngine

/// Meetings: ambient capture with a name, and an export when it ends. Session titles set over the socket land here too.
extension SpeechService {
    /// A meeting is ambient capture with a name, and an export when it ends.
    func startMeeting(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { notice = "Give the meeting a name first."; return }
        do {
            try await startAmbient()
            guard ambientEnabled else { throw JotError.message("Ambient capture did not start.") }
            meetingTitle = trimmed
            let store = library.store, id = timeline.sessionID
            try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: trimmed) }.value
            library.refreshSessions()
        } catch { meetingTitle = nil; notice = error.localizedDescription }
    }

    /// Renames the running meeting: the name goes on its session now and on any continuation after an automatic pause.
    func renameMeeting(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meetingTitle != nil, !trimmed.isEmpty, let id = timeline.activeSessionID else { return }
        meetingTitle = trimmed; library.renameSession(id, title: trimmed)
    }

    /// Names any session from the socket. Naming the running meeting's session renames the meeting too, so the Live chip and a continuation after an automatic pause use the new name.
    func setSessionTitle(_ id: String, title: String) async throws {
        let store = library.store
        guard !(await library.waitForDeletion(id)) else { throw JotError.message("Session was deleted.") }
        try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: title) }.value
        library.refreshSessions()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if meetingTitle != nil, id == timeline.activeSessionID, !trimmed.isEmpty { meetingTitle = trimmed }
    }

    /// A meeting kept through an automatic pause records on into a new session under the same name. The earlier part stays in Sessions, and TranscriptExport.write adds " (2)" to a duplicate file name.
    func continueMeeting() async throws {
        guard let meetingTitle, ambientEnabled else { return }
        let store = library.store, id = timeline.sessionID
        try await storeExecutor.submit { try store?.setTitle(sessionID: id, title: meetingTitle) }.value
        library.refreshSessions()
    }

    /// Closes and exports the named session while continuous listening immediately
    /// continues in a fresh untitled session.
    @discardableResult
    func endMeeting() async -> URL? {
        guard !pauseRequested else {
            notice = "Wait for Pause to finish before exporting the meeting."
            return nil
        }
        guard !dictation.isActive, !dictation.isPending else {
            notice = "Finish the held dictation before ending the meeting."
            return nil
        }
        library.clearLastExport()
        let id = timeline.sessionID
        let generation = lifecycle.generation
        if ambientEnabled { drainAudio(); timeline.flushAmbient(final: true) }
        let throughOffset = timeline.ambientOffset
        timeline.endSessionAudio(runPass: true)
        meetingTitle = nil
        if ambientEnabled {
            timeline.beginSession(at: dependencies.now())
            recordEvent(.started, "Listening continued in a fresh session after meeting export.")
            transcriber.kick()
        }
        if lifecycle.acceptsWork(generation) {
            await transcriber.waitUntilProcessed(sessionID: id, through: throughOffset)
            if !lifecycle.acceptsWork(generation) {
                notice = "Meeting export interrupted. Saved transcripts remain in Sessions; no file was exported."
                return nil
            }
        }
        library.refreshSessions()
        // A meeting with nothing transcribed ends quietly; there is no file to show.
        let store = library.store
        guard (try? await storeExecutor.perform { try store?.session(id: id).isEmpty }) == false else { return nil }
        do {
            let url = try await library.exportSession(id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch { notice = error.localizedDescription; return nil }
    }
}
