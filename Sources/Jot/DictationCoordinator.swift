import AppKit
import Foundation
import JotCore

/// One held dictation at a time: the attempt record it saves while the key is down, the text it gathers from the listening timeline on release, the insertion, and the saved text available for explicit review.
@MainActor
final class DictationCoordinator {
    /// The listening state, and with it the menu icon, reads this through the service; a change redraws it rather than relying on the notice set nearby.
    private(set) var isActive = false {
        willSet { service.objectWillChange.send() }
        didSet { service.refreshShortcutEligibility() }
    }
    /// The shortcut button, the microphone picker and Update read this through the service, and a release can end with no other service change, so a change redraws them. It changes a few times per hold.
    private(set) var isPending = false {
        willSet { service.objectWillChange.send() }
        didSet { service.refreshShortcutEligibility() }
    }
    private var ticket = UUID()
    private var started = Date()
    private(set) var currentAttempt: DictationAttempt?
    private var attemptEndOffset: Double?
    private var recoveryTask: Task<Void, Never>?
    private var discardedAttemptIDs = Set<String>()
    private var attemptHadGap = false
    /// The entries enabled when the hold began, so a mid-hold edit does not change what gets inserted.
    private var vocabulary = PersonalVocabulary()
    private let speakerMute = DictationSpeakerMute()
    private let highlight = DictationHighlight()
    private unowned let service: SpeechService
    private let timeline: ListeningTimeline
    private let library: SessionLibrary
    private let cleanup: LiveCleanup
    private let transcriber: Transcriber

    init(service: SpeechService, timeline: ListeningTimeline, library: SessionLibrary,
         cleanup: LiveCleanup, transcriber: Transcriber) {
        self.service = service
        self.timeline = timeline
        self.library = library
        self.cleanup = cleanup
        self.transcriber = transcriber
    }

    /// True while release work or recovery is still finishing; the harness waits on it.
    var isBusy: Bool { isPending || recoveryTask != nil }
    var recoveryRunning: Bool { recoveryTask != nil }

    /// Submission happens before returning to the key callback, preserving its order
    /// against recognition writes and an explicit discard on the same store queue.
    private func submitSave(_ attempt: DictationAttempt) -> StoreOperation<Void>? {
        guard let store = library.store else { return nil }
        return library.storeExecutor.submit { try store.saveDictationAttempt(attempt) }
    }

    private func save(_ attempt: DictationAttempt) async throws {
        guard !(await library.waitForDeletion(attempt.sessionID)) else { throw CancellationError() }
        if let operation = submitSave(attempt) { try await operation.value }
    }

    private func isCurrent(_ id: String, session: String) -> Bool {
        !Task.isCancelled && !discardedAttemptIDs.contains(id) &&
        !library.sessionIsDeleted(session) && currentAttempt?.id == id
    }

    private func isCurrentAfterDeletion(_ id: String, session: String) async -> Bool {
        guard !(await library.waitForDeletion(session)) else { return false }
        return isCurrent(id, session: session)
    }

    func begin() {
        guard service.canHoldDictation, !isPending, !isActive else { return }
        // Close the pre-gesture chunk so the held range starts on an exact timeline
        // boundary even when the target field could not be acquired.
        service.closeChunk()
        if service.muteSpeakersDuringDictation { speakerMute.begin() }
        vocabulary = service.vocabulary
        cleanup.cancelDictationCleanup()
        started = timeline.sessionStarted.addingTimeInterval(timeline.ambientOffset)
        ticket = UUID(); isActive = true; attemptHadGap = false
        let attempt = DictationAttempt(id: ticket.uuidString, sessionID: timeline.sessionID,
            startedAt: started, state: .capturing, updatedAt: started)
        currentAttempt = attempt
        if let operation = submitSave(attempt) {
            let owner = service
            Task { [weak self] in
                defer { withExtendedLifetime(owner) {} }
                do { try await operation.value }
                catch {
                    guard let self, await self.isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return }
                    service.recoveryNotice = "Dictation started, but its recovery record could not be saved."
                }
            }
        }
        if service.highlightTargetField { highlight.show(follow: { [weak self] in self?.service.input.targetFrame() }) }
        service.markPerformance(.dictationStarted)
        service.notice = "Listening for dictation… release \(service.shortcut.displayName) to insert."
    }

    /// `releasedAt` is the key event's own time (system uptime). Latency is measured from it, so a stalled main thread that
    /// delays this call lengthens the figure instead of hiding in it. A time that is not from this clock falls back to now.
    func end(releasedAt eventTime: Double = ProcessInfo.processInfo.systemUptime) {
        speakerMute.end()
        guard isActive, var attempt = currentAttempt else { highlight.hide(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let released = eventTime <= now && now - eventTime < 5 ? eventTime : now
        service.closeChunk()
        isActive = false
        isPending = true
        service.markPerformance(.dictationReleased)
        attempt.endedAt = max(attempt.startedAt, timeline.sessionStarted.addingTimeInterval(timeline.ambientOffset))
        attempt.state = .recognizing
        attempt.updatedAt = attempt.endedAt!
        currentAttempt = attempt
        attemptEndOffset = timeline.ambientOffset
        if let operation = submitSave(attempt) {
            let owner = service
            Task { [weak self] in
                defer { withExtendedLifetime(owner) {} }
                do { try await operation.value }
                catch {
                    guard let self, await self.isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return }
                    service.recoveryNotice = "Dictation ended, but its recovery record could not be updated."
                }
            }
        }
        service.notice = "Finishing saved dictation…"
        transcriber.kick()
        recoveryTask?.cancel()
        let owner = service
        recoveryTask = Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            await self?.finishAttempt(id: attempt.id, throughOffset: self?.attemptEndOffset ?? 0, releasedAt: released)
        }
    }

    /// A tap explicitly discards only the current held intent. Continuous listening
    /// rows and earlier saved dictations remain untouched.
    func cancelTap() {
        speakerMute.end(); highlight.hide()
        if isActive || isPending { service.markPerformance(.dictationCancelled) }
        service.input.discardTarget()
        if let id = currentAttempt?.id {
            discardedAttemptIDs.insert(id)
            if let store = library.store {
                let operation = library.storeExecutor.submit { try store.deleteDictationAttempt(id: id) }
                Task { try? await operation.value }
            }
        }
        recoveryTask?.cancel(); recoveryTask = nil
        isActive = false; isPending = false; ticket = UUID()
        currentAttempt = nil; attemptEndOffset = nil
        attemptHadGap = false
        service.recoveryNotice = "Current dictation discarded. Listening history was kept."
    }

    /// Lost or dropped audio inside a hold marks the attempt partial; outside a hold there is nothing to mark.
    func markGap(_ recoveryNotice: String) {
        guard isActive || isPending else { return }
        attemptHadGap = true
        service.recoveryNotice = recoveryNotice
    }

    /// A recognition failure over the held range marks the attempt partial.
    func noteRecognitionFailure(for job: AudioJob) {
        guard let attempt = currentAttempt, attempt.sessionID == job.sessionID,
              attempt.state == .capturing || attempt.state == .recognizing,
              job.startedAt.addingTimeInterval(job.offset + AudioClock.seconds(samples: job.samples.count)) > attempt.startedAt,
              job.startedAt.addingTimeInterval(job.offset - (job.isFinal ? 2 : 0)) < (attempt.endedAt ?? .distantFuture) else { return }
        attemptHadGap = true
        service.recoveryNotice = "Some dictation could not be recognized. The recognized parts were kept for review."
    }

    /// Clear in Dictations drops the live attempt along with the rows.
    func discardForHistoryReset() {
        if let id = currentAttempt?.id { discardedAttemptIDs.insert(id) }
        recoveryTask?.cancel(); recoveryTask = nil
        currentAttempt = nil; isActive = false; isPending = false
        speakerMute.end(); highlight.hide(); service.input.discardTarget()
    }

    /// Rows deleted from Dictations must not come back through a pending attempt built on them.
    func discard(ids: [String]) { discardedAttemptIDs.formUnion(ids) }

    func waitForRecovery() async {
        if let recoveryTask { await recoveryTask.value }
        await library.storeExecutor.flush()
    }

    func releaseFieldEffects() { speakerMute.end(); highlight.hide() }
    func endSpeakerMute() { speakerMute.end() }
    func hideHighlight() { highlight.hide() }

    /// One held dictation's timings for `jot diagnostics`, measured from release. Numbers and outcome names only.
    private struct Timing {
        let released: Double
        var holdSeconds = 0.0
        var recognitionSeconds = 0.0
        var cleanupSeconds: Double?
        var cleanupOutcome: String?
        var deliverySeconds: Double?
        var outcome = PerformanceJob.Outcome.cancelled
        var completionSeconds: Double?

        static var now: Double { ProcessInfo.processInfo.systemUptime }
        var sinceRelease: Double { max(0, Self.now - released) }
        mutating func finish(_ outcome: PerformanceJob.Outcome, at uptime: Double = Timing.now) {
            self.outcome = outcome
            completionSeconds = max(0, uptime - released)
        }
        var job: PerformanceJob {
            .init(elapsedSeconds: 0, mode: .dictation, outcome: outcome, audioSeconds: holdSeconds, queueWaitSeconds: recognitionSeconds,
                  inferenceSeconds: nil, completionSeconds: completionSeconds ?? sinceRelease, cleanupSeconds: cleanupSeconds,
                  deliverySeconds: deliverySeconds, cleanupOutcome: cleanupOutcome)
        }
    }

    private func finishAttempt(id: String, throughOffset: Double, releasedAt released: Double) async {
        // The outline stays through recognition, cleanup, and insertion; a newer hold keeps its own.
        defer {
            if currentAttempt?.id == id {
                service.input.discardTarget()
                isPending = false
                attemptEndOffset = nil
                if let session = currentAttempt?.sessionID, library.sessionIsDeleted(session) { currentAttempt = nil }
                recoveryTask = nil
            }
        }
        defer { if !isActive { highlight.hide() } }
        // Every released hold records one timing; one that never finishes is recorded as cancelled.
        var timing = Timing(released: released)
        defer { service.recordPerformance(timing.job) }
        guard let started = currentAttempt, started.id == id else { return }
        timing.holdSeconds = max(0, (started.endedAt ?? started.startedAt).timeIntervalSince(started.startedAt))
        await transcriber.waitUntilProcessed(sessionID: started.sessionID, through: throughOffset)
        timing.recognitionSeconds = timing.sinceRelease
        guard await isCurrentAfterDeletion(id, session: started.sessionID),
              var attempt = currentAttempt, attempt.id == id else { return }
        do {
            let store = library.store
            let lowerBound = attempt.startedAt
            let upperBound = attempt.endedAt ?? service.dependencies.now()
            let read = library.storeExecutor.submit {
                try store?.recoveryText(from: lowerBound, through: upperBound) ?? ""
            }
            let raw = try await read.value
            guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
            let prepared = DictationCleanup.prepare(raw, vocabulary: vocabulary)
            var text = prepared.text
            if service.cleanUpDictation, prepared.needsProseCleanup, !text.isEmpty {
                let began = Timing.now
                let cleaned = await cleanup.cleanDictation(text)
                text = cleaned.text
                timing.cleanupSeconds = max(0, Timing.now - began)
                timing.cleanupOutcome = cleaned.outcome.rawValue
            }
            guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
            attempt.text = text
            attempt.hasGap = attemptHadGap
            attempt.updatedAt = service.dependencies.now()
            if text.isEmpty || attemptHadGap {
                attempt.state = .deliveryFailed
                try await save(attempt)
                guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
                currentAttempt = attempt
                if attemptHadGap {
                    service.recoveryNotice = "Partial dictation was saved after an audio gap. It was not inserted automatically."
                    service.notice = "Dictation has an audio gap; review the saved text before retrying."
                } else {
                    service.recoveryNotice = "No speech was recognized for that hold. Recent listening history is still available."
                    service.notice = "No text to insert."
                }
                timing.finish(attemptHadGap ? .failed : .noSpeech)
            } else {
                attempt.state = .ready
                try await save(attempt)
                guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
                // History gets one durable dictation row, while the underlying listening
                // timeline remains the recognition source of truth.
                if !discardedAttemptIDs.contains(attempt.id) {
                    let duration = max(0, (attempt.endedAt ?? attempt.updatedAt).timeIntervalSince(attempt.startedAt))
                    let row = Transcript(id: attempt.id, sessionID: attempt.sessionID,
                        startedAt: attempt.startedAt, startSeconds: 0, endSeconds: duration,
                        text: text, mode: "dictation")
                    // The row belongs to the listening session too, so Live shows it once it is saved.
                    do {
                        if let store = library.store {
                            let write = library.storeExecutor.submit { try store.append(row) }
                            try await write.value
                            if await isCurrentAfterDeletion(id, session: started.sessionID) { library.appendLive([row]) }
                        }
                    } catch {
                        // A row that cannot be saved is left out of History and Live; the attempt is saved and still delivers.
                    }
                }
                guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
                currentAttempt = attempt
                if let delivery = await deliverAttempt(attempt) {
                    timing.deliverySeconds = delivery.seconds
                    timing.finish(delivery.outcome, at: delivery.finishedUptime)
                }
            }
        } catch {
            guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
            // Still recognizing means reading the held range failed, so the text is the words the blocks saved.
            if attempt.state == .recognizing {
                attempt.text = DictationCleanup.prepare(attempt.text, vocabulary: vocabulary).text
            }
            attempt.state = .deliveryFailed; attempt.updatedAt = service.dependencies.now()
            try? await save(attempt)
            guard await isCurrentAfterDeletion(id, session: started.sessionID) else { return }
            currentAttempt = attempt
            service.recoveryNotice = "Dictation was saved but could not be finished. Choose Review saved dictation to copy the saved text."
            service.notice = "Dictation: \(error.localizedDescription)"
            timing.finish(.failed)
        }
        library.refreshRecent()
    }

    /// Returns how delivery ended and how long insertion took, or nil when the attempt was discarded.
    @discardableResult
    private func deliverAttempt(_ original: DictationAttempt) async -> (outcome: PerformanceJob.Outcome, seconds: Double, finishedUptime: Double)? {
        var attempt = original
        guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
        let began = Timing.now
        do {
            let delivery = try await service.dependencies.deliver(service.input, attempt.text)
            let finished = Timing.now
            let timing = (outcome: delivery.verified ? PerformanceJob.Outcome.completed : .deliveryUnverified,
                          seconds: max(0, finished - began), finishedUptime: finished)
            guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
            attempt.state = delivery.verified ? .delivered : .deliveryUnverified
            attempt.updatedAt = service.dependencies.now()
            currentAttempt = attempt
            do { try await save(attempt) }
            catch {
                guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
                service.recoveryNotice = "Text was sent, but its delivery record could not be saved. Check the field before copying saved text to avoid duplicates."
                service.notice = "Could not save delivery status: \(error.localizedDescription)"
                return timing
            }
            guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
            if delivery.verified {
                highlight.finish()
                service.recoveryNotice = attempt.hasGap ? "Saved partial dictation inserted. Some audio was not recognized; review the text." : "Dictation inserted."
            } else {
                service.recoveryNotice = attempt.hasGap
                    ? "Partial dictation was sent, but insertion could not be verified. Check the field before retrying."
                    : "Dictation was saved, but insertion could not be verified. Choose Review saved dictation to copy the saved text."
            }
            service.notice = ""
            return timing
        } catch {
            let finished = Timing.now
            guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
            attempt.state = .deliveryFailed; attempt.updatedAt = service.dependencies.now()
            try? await save(attempt)
            guard await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID) else { return nil }
            currentAttempt = attempt
            service.recoveryNotice = attempt.hasGap
                ? "Partial dictation was saved. Choose Review saved dictation to copy the recognized portion."
                : "Dictation was saved. Choose Review saved dictation to copy it."
            service.notice = "Text was not inserted: \(error.localizedDescription)"
            return (.failed, max(0, finished - began), finished)
        }
    }

    /// Each recognized block inside the hold refreshes the saved attempt text, so a crash mid-hold loses only the unrecognized tail.
    func updateAttemptText(for job: AudioJob) {
        guard let attempt = currentAttempt, attempt.sessionID == job.sessionID,
              !discardedAttemptIDs.contains(attempt.id),
              attempt.state == .capturing || attempt.state == .recognizing,
              let store = library.store else { return }
        let upperBound = attempt.endedAt ?? service.dependencies.now()
        let updatedAt = service.dependencies.now()
        let hadGap = attemptHadGap
        let operation = library.storeExecutor.submit { () throws -> DictationAttempt? in
            let text = try store.recoveryText(from: attempt.startedAt, through: upperBound)
            guard !text.isEmpty else { return nil }
            var updated = attempt
            updated.text = text
            updated.hasGap = hadGap
            updated.updatedAt = updatedAt
            try store.saveDictationAttempt(updated)
            return updated
        }
        let owner = service
        Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do {
                guard let updated = try await operation.value,
                      await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID),
                      currentAttempt?.state == attempt.state else { return }
                currentAttempt = updated
                if isActive { service.recoveryNotice = "Dictation is being saved as you speak." }
            } catch {
                if await isCurrentAfterDeletion(attempt.id, session: attempt.sessionID), currentAttempt?.state == attempt.state {
                    service.recoveryNotice = "Speech is still being recognized, but the recovery record could not be updated."
                }
            }
        }
    }

    /// A hold cut short by quit saved only the words as recognized. Launch converts symbols, vocabulary, and hesitations once so recovery inserts dictation text; the optional model cleanup that release runs is skipped.
    func finalizeInterruptedAttempts() async throws {
        let store = library.store, vocabulary = service.vocabulary
        try await library.storeExecutor.submit {
            try store?.finalizeInterruptedDictationAttempts(converting: { words in
                DictationCleanup.prepare(words, vocabulary: vocabulary).text
            })
        }.value
    }

    /// A snapshot for explicit review/copy. It never acquires a field, starts capture, generates text,
    /// consumes the attempt, or substitutes ambient speech. Reopening review reads the store again.
    func savedDictationForReview() async throws -> DictationAttempt? {
        guard !isActive, !isPending else {
            throw JotError.message("Finish the current dictation before reviewing saved text.")
        }
        guard let store = library.store else { throw JotError.message("Saved history is unavailable.") }
        return try await library.storeExecutor.perform {
            try store.latestRecoverableDictationAttempt()
        }
    }
}
