import AppKit
import Foundation
import JotCore

/// What a held dictation needs from the service: the listening timeline it marks a range on, the store, the field it inserts into, and a place to report.
@MainActor
protocol DictationHost: AnyObject {
    var store: TranscriptStore? { get }
    var input: DictationInput { get }
    var dependencies: SpeechServiceDependencies { get }
    var notice: String { get set }
    var recoveryNotice: String { get set }
    var vocabulary: PersonalVocabulary { get }
    var cleanUpDictation: Bool { get }
    var recoveryLookbackSeconds: Int { get }
    var shortcutName: String { get }
    var sessionID: String { get }
    var sessionStarted: Date { get }
    var ambientOffset: Double { get }
    var recognitionFailures: Int { get }
    /// Models loaded, microphone on, no pause under way.
    var canHoldDictation: Bool { get }
    var highlightTargetField: Bool { get }
    var muteSpeakersDuringDictation: Bool { get }
    func sessionIsDeleted(_ id: String) -> Bool
    /// Closes the audio chunk in progress so a held range starts or ends on an exact timeline boundary.
    func closeChunk()
    func kickWorker()
    func waitUntilProcessed(sessionID: String, through offset: Double) async
    func markPerformance(_ kind: PerformanceEventKind)
    func updateMode()
    func refreshRecent()
    func cancelDictationCleanup()
    func cleanDictation(_ text: String) async -> String
}

/// One held dictation at a time: the attempt record it saves while the key is down, the text it gathers from the listening timeline on release, the insertion, and the double-tap recovery of anything undelivered.
@MainActor
final class DictationCoordinator {
    private(set) var isActive = false
    private(set) var isPending = false
    private(set) var ticket = UUID()
    private var started = Date()
    private(set) var currentAttempt: DictationAttempt?
    private var attemptEndOffset: Double?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryDeliveryTask: Task<Void, Never>?
    private var discardedAttemptIDs = Set<String>()
    private var attemptHadGap = false
    private var deliveryStateSaveFailed = false
    /// The entries enabled when the hold began, so a mid-hold edit does not change what gets inserted.
    private var vocabulary = PersonalVocabulary()
    private let speakerMute = DictationSpeakerMute()
    private let highlight = DictationHighlight()
    private unowned let host: DictationHost

    init(host: DictationHost) { self.host = host }

    /// True while release work or recovery is still finishing; the harness waits on it.
    var isBusy: Bool { isPending || recoveryTask != nil }
    var recoveryRunning: Bool { recoveryTask != nil || recoveryDeliveryTask != nil }

    func begin() {
        guard host.canHoldDictation, !isPending, !isActive else { return }
        // Close the pre-gesture chunk so the held range starts on an exact timeline
        // boundary even when the target field could not be acquired.
        host.closeChunk()
        if host.muteSpeakersDuringDictation { speakerMute.begin() }
        vocabulary = host.vocabulary
        host.cancelDictationCleanup()
        started = host.sessionStarted.addingTimeInterval(host.ambientOffset)
        ticket = UUID(); isActive = true; attemptHadGap = false
        let attempt = DictationAttempt(id: ticket.uuidString, sessionID: host.sessionID,
            startedAt: started, state: .capturing, updatedAt: started)
        currentAttempt = attempt
        do { try host.store?.saveDictationAttempt(attempt) }
        catch { host.recoveryNotice = "Dictation started, but its recovery record could not be saved." }
        if host.highlightTargetField { highlight.show(follow: { [weak self] in self?.host.input.targetFrame() }) }
        host.updateMode()
        host.markPerformance(.dictationStarted)
        host.notice = "Listening for dictation… release \(host.shortcutName) to insert."
    }

    /// Returns true when a hold ended, so the caller can drop the level meter.
    @discardableResult
    func end() -> Bool {
        speakerMute.end(); highlight.hide()
        guard isActive, var attempt = currentAttempt else { return false }
        host.closeChunk()
        isActive = false
        isPending = true
        host.markPerformance(.dictationReleased)
        host.updateMode()
        attempt.endedAt = max(attempt.startedAt, host.sessionStarted.addingTimeInterval(host.ambientOffset))
        attempt.state = .recognizing
        attempt.updatedAt = attempt.endedAt!
        currentAttempt = attempt
        attemptEndOffset = host.ambientOffset
        do { try host.store?.saveDictationAttempt(attempt) }
        catch { host.recoveryNotice = "Dictation ended, but its recovery record could not be updated." }
        host.notice = "Finishing saved dictation…"
        host.kickWorker()
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            await self?.finishAttempt(id: attempt.id, throughOffset: self?.attemptEndOffset ?? 0)
        }
        return true
    }

    /// A tap explicitly discards only the current held intent. Continuous listening
    /// rows and the recovery window remain untouched.
    func cancelTap() {
        speakerMute.end(); highlight.hide()
        if isActive || isPending { host.markPerformance(.dictationCancelled) }
        host.input.discardTarget()
        if let id = currentAttempt?.id {
            discardedAttemptIDs.insert(id)
            try? host.store?.deleteDictationAttempt(id: id)
        }
        recoveryTask?.cancel(); recoveryTask = nil
        isActive = false; isPending = false; ticket = UUID()
        currentAttempt = nil; attemptEndOffset = nil
        attemptHadGap = false
        host.recoveryNotice = "Current dictation discarded. Listening history was kept."
        host.updateMode()
    }

    /// Lost or dropped audio inside a hold marks the attempt partial; outside a hold there is nothing to mark.
    func markGap(_ recoveryNotice: String) {
        guard isActive || isPending else { return }
        attemptHadGap = true
        host.recoveryNotice = recoveryNotice
    }

    /// A recognition failure over the held range marks the attempt partial.
    func noteRecognitionFailure(for job: AudioJob) {
        guard let attempt = currentAttempt, attempt.sessionID == job.sessionID,
              attempt.state == .capturing || attempt.state == .recognizing,
              job.startedAt.addingTimeInterval(job.offset + AudioClock.seconds(samples: job.samples.count)) > attempt.startedAt,
              job.startedAt.addingTimeInterval(job.offset - (job.isFinal ? 2 : 0)) < (attempt.endedAt ?? .distantFuture) else { return }
        attemptHadGap = true
        host.recoveryNotice = "Some dictation could not be recognized. The recognized parts were kept for review."
    }

    /// Clear in Dictations drops the live attempt along with the rows.
    func discardForHistoryReset() {
        if let id = currentAttempt?.id { discardedAttemptIDs.insert(id) }
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryDeliveryTask?.cancel(); recoveryDeliveryTask = nil
        currentAttempt = nil; isActive = false; isPending = false
        speakerMute.end(); highlight.hide(); host.input.discardTarget()
    }

    /// Rows deleted from Dictations must not come back through a pending attempt built on them.
    func discard(ids: [String]) { discardedAttemptIDs.formUnion(ids) }

    func waitForRecovery() async {
        if let recoveryTask { await recoveryTask.value }
        if let recoveryDeliveryTask { await recoveryDeliveryTask.value }
    }

    func releaseFieldEffects() { speakerMute.end(); highlight.hide() }
    func endSpeakerMute() { speakerMute.end() }
    func hideHighlight() { highlight.hide() }

    private func finishAttempt(id: String, throughOffset: Double) async {
        guard let started = currentAttempt, started.id == id else { recoveryTask = nil; return }
        await host.waitUntilProcessed(sessionID: started.sessionID, through: throughOffset)
        guard !Task.isCancelled, !discardedAttemptIDs.contains(id), !host.sessionIsDeleted(started.sessionID),
              var attempt = currentAttempt, attempt.id == id else { recoveryTask = nil; return }
        do {
            let raw = try host.store?.recoveryText(from: attempt.startedAt, through: attempt.endedAt ?? host.dependencies.now()) ?? ""
            var text = DictationCleanup.applying(to: vocabulary.applyingToDictation(raw))
            if host.cleanUpDictation, !text.isEmpty { text = await host.cleanDictation(text) }
            guard !Task.isCancelled, !discardedAttemptIDs.contains(id) else { recoveryTask = nil; return }
            attempt.text = text
            attempt.hasGap = attemptHadGap
            attempt.updatedAt = host.dependencies.now()
            if text.isEmpty || attemptHadGap {
                attempt.state = .deliveryFailed
                try host.store?.saveDictationAttempt(attempt)
                currentAttempt = attempt
                if attemptHadGap {
                    host.recoveryNotice = "Partial dictation was saved after an audio gap. It was not inserted automatically."
                    host.notice = "Dictation has an audio gap; review the saved text before retrying."
                } else {
                    host.recoveryNotice = "No speech was recognized for that hold. Recent listening history is still available."
                    host.notice = "No text to insert."
                }
            } else {
                attempt.state = .ready
                try host.store?.saveDictationAttempt(attempt)
                // History gets one durable dictation row, while the underlying listening
                // timeline remains the recognition source of truth.
                if !discardedAttemptIDs.contains(attempt.id) {
                    let duration = max(0, (attempt.endedAt ?? attempt.updatedAt).timeIntervalSince(attempt.startedAt))
                    try? host.store?.append(Transcript(id: attempt.id, sessionID: attempt.sessionID,
                        startedAt: attempt.startedAt, startSeconds: 0, endSeconds: duration,
                        text: text, mode: "dictation"))
                }
                currentAttempt = attempt
                await deliverAttempt(attempt)
            }
        } catch {
            attempt.state = .deliveryFailed; attempt.updatedAt = host.dependencies.now()
            try? host.store?.saveDictationAttempt(attempt)
            currentAttempt = attempt
            host.recoveryNotice = "Dictation was saved but could not be finished. Use the recovery gesture to retry."
            host.notice = "Dictation: \(error.localizedDescription)"
        }
        host.input.discardTarget()
        isPending = false; attemptEndOffset = nil; recoveryTask = nil
        host.refreshRecent()
    }

    private func deliverAttempt(_ original: DictationAttempt) async {
        var attempt = original
        guard !discardedAttemptIDs.contains(attempt.id), !host.sessionIsDeleted(attempt.sessionID) else { return }
        do {
            let delivery = try await host.dependencies.deliver(host.input, attempt.text)
            guard !discardedAttemptIDs.contains(attempt.id), !host.sessionIsDeleted(attempt.sessionID) else { return }
            attempt.state = delivery.verified ? .delivered : .deliveryUnverified
            attempt.updatedAt = host.dependencies.now()
            currentAttempt = attempt
            do { try host.store?.saveDictationAttempt(attempt) }
            catch {
                deliveryStateSaveFailed = true
                host.recoveryNotice = "Text was sent, but its delivery record could not be saved. Check the field; automatic recovery is blocked to avoid duplicates."
                host.notice = "Could not save delivery status: \(error.localizedDescription)"
                return
            }
            if delivery.verified {
                host.recoveryNotice = attempt.hasGap ? "Saved partial dictation inserted. Some audio was not recognized; review the text." : "Dictation inserted."
            } else {
                host.recoveryNotice = attempt.hasGap
                    ? "Partial dictation was sent, but insertion could not be verified. Check the field before retrying."
                    : "Dictation was saved, but insertion could not be verified. Use the recovery gesture to retry."
            }
            host.notice = ""
        } catch {
            guard !discardedAttemptIDs.contains(attempt.id), !host.sessionIsDeleted(attempt.sessionID) else { return }
            attempt.state = .deliveryFailed; attempt.updatedAt = host.dependencies.now()
            try? host.store?.saveDictationAttempt(attempt)
            currentAttempt = attempt
            host.recoveryNotice = attempt.hasGap
                ? "Partial dictation was saved. Review it in Sessions; focus a field and use recovery to insert the recognized portion."
                : "Dictation was saved. Focus a text field and use the recovery gesture to retry."
            host.notice = "Text was not inserted: \(error.localizedDescription)"
        }
    }

    /// Each recognized block inside the hold refreshes the saved attempt text, so a crash mid-hold loses only the unrecognized tail.
    func updateAttemptText(for job: AudioJob) {
        guard var attempt = currentAttempt, attempt.sessionID == job.sessionID,
              !discardedAttemptIDs.contains(attempt.id),
              attempt.state == .capturing || attempt.state == .recognizing else { return }
        do {
            let text = try host.store?.recoveryText(from: attempt.startedAt, through: attempt.endedAt ?? host.dependencies.now()) ?? ""
            guard !text.isEmpty else { return }
            attempt.text = text; attempt.hasGap = attemptHadGap; attempt.updatedAt = host.dependencies.now()
            try host.store?.saveDictationAttempt(attempt)
            currentAttempt = attempt
            host.recoveryNotice = isActive ? "Dictation is being saved as you speak." : host.recoveryNotice
        } catch {
            host.recoveryNotice = "Speech is still being recognized, but the recovery record could not be updated."
        }
    }

    /// Uses the target already acquired by DictationInput's recovery callback.
    func recoverRecent() {
        guard !deliveryStateSaveFailed else {
            host.recoveryNotice = "A previous insertion could not save its delivery status. Check the target field and copy saved text from Sessions to avoid duplicate insertion."
            return
        }
        guard host.canHoldDictation, !isActive, !isPending else {
            host.recoveryNotice = "Resume listening before recovering speech."
            return
        }
        guard recoveryDeliveryTask == nil else {
            host.recoveryNotice = "Recovery is already finishing captured speech."
            return
        }
        let failuresBeforeRecovery = host.recognitionFailures
        host.closeChunk()
        let triggerTime = host.sessionStarted.addingTimeInterval(host.ambientOffset)
        let triggerSession = host.sessionID
        let triggerOffset = host.ambientOffset
        let lookback = Double(host.recoveryLookbackSeconds)
        isPending = true
        host.recoveryNotice = "Finishing speech captured before the recovery gesture…"
        host.kickWorker()
        recoveryDeliveryTask = Task { [weak self] in
            guard let self else { return }
            await host.waitUntilProcessed(sessionID: triggerSession, through: triggerOffset)
            guard !Task.isCancelled else { recoveryDeliveryTask = nil; isPending = false; return }
            do {
                let failed = try host.store?.latestRecoverableDictationAttempt()
                let recent = try host.store?.recoveryText(from: triggerTime.addingTimeInterval(-lookback), through: triggerTime) ?? ""
                guard let selection = DictationRecovery.select(attempt: failed, recentSpeech: recent) else {
                    host.recoveryNotice = "No saved or recent speech was found to insert."
                    host.input.discardTarget(); isPending = false; recoveryDeliveryTask = nil; return
                }
                var attempt: DictationAttempt
                switch selection.source {
                case .failedAttempt:
                    attempt = failed!
                case .recentSpeech:
                    let start = triggerTime.addingTimeInterval(-lookback)
                    attempt = DictationAttempt(sessionID: triggerSession, startedAt: start,
                        endedAt: triggerTime, text: DictationCleanup.applying(to: host.vocabulary.applyingToDictation(selection.text)),
                        state: host.recognitionFailures == failuresBeforeRecovery ? .ready : .deliveryFailed,
                        hasGap: host.recognitionFailures != failuresBeforeRecovery, updatedAt: host.dependencies.now())
                    try host.store?.saveDictationAttempt(attempt)
                }
                currentAttempt = attempt
                if selection.source == .recentSpeech && attempt.hasGap {
                    host.recoveryNotice = "Recent speech is partially saved, but finishing its audio failed. Review Sessions; use recovery again to insert the recognized portion."
                } else {
                    await deliverAttempt(attempt)
                }
            } catch {
                host.recoveryNotice = "Recovery could not finish. Saved speech was kept for another retry."
                host.notice = error.localizedDescription
            }
            host.input.discardTarget(); isPending = false; recoveryDeliveryTask = nil
        }
    }
}
