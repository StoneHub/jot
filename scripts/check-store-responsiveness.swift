import Foundation
import JotCore
import SQLite3

extension RecoveryFlowChecks {
    private static func isSignaled(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    /// Uses isolated synthetic history and a deliberately held executor, never
    /// the installed app's store. A session switch must not wait on SQLite or
    /// accept an earlier session's late snapshot.
    @MainActor static func checkLibraryReadsStayResponsive(directory: URL) async throws {
        let folder = directory.appendingPathComponent("large-history", isDirectory: true)
        let store = try TranscriptStore(directory: folder)
        let service = SpeechService()
        service.beginRecoveryVerification(store: store, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        defer { service.shutdown() }
        let executor = service.library.storeExecutor
        try await executor.perform {
            for index in 0..<7_000 {
                try store.append(Transcript(id: "row-\(index)", sessionID: index < 3_500 ? "A" : "B",
                    startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    startSeconds: Double(index), endSeconds: Double(index) + 0.5,
                    text: "synthetic segment \(index)", mode: index % 10 == 0 ? "dictation" : "ambient"))
            }
        }
        await service.library.waitForReads()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            try await executor.perform {
                started.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw StoreError.invalid("Screen reads blocked the main actor")
                }
            }
        }
        while !isSignaled(started) {
            try await Task.sleep(for: .milliseconds(1))
        }
        defer { release.signal() }
        let monitorStarted = ContinuousClock.now
        let monitor = Task { @MainActor () -> Duration in
            var previous = monitorStarted
            var longest = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longest = max(longest, previous.duration(to: now) - .milliseconds(5))
                previous = now
            }
            return longest
        }
        let began = ContinuousClock.now
        service.library.showLive("A")
        service.library.refreshRecent()
        service.library.refreshSessions()
        service.library.searchHistory("synthetic")
        service.library.showLive("B")
        let elapsed = began.duration(to: .now)
        precondition(elapsed < .milliseconds(50), "Screen actions blocked on queued store work: \(elapsed)")
        // Let both requests reach their suspension before releasing the queue.
        try await Task.sleep(for: .milliseconds(20))
        release.signal()
        try await blocker.value
        await service.library.waitForReads()
        precondition(service.library.live.sessionID == "B", "A late read replaced the selected session")
        precondition(!service.library.live.paragraphs.isEmpty && service.library.live.paragraphs.allSatisfy { $0.sessionID == "B" },
            "Live displayed another session's rows after a switch")
        let paragraphs = await service.library.sessionParagraphs("B")
        monitor.cancel()
        let gap = await monitor.value
        precondition(gap < .milliseconds(50), "History reads stalled the main actor: \(gap)")
        precondition(service.library.live.paragraphs == paragraphs, "Live lost rows while reads were pending")
        precondition(service.library.sessions.count == 2, "The queued Sessions read did not finish")
        precondition(!service.library.history.isEmpty && service.library.dictationCount == 700,
            "The queued Dictations search did not read the synthetic history")
        print("PASS: 7,000-row history reads leave the main actor free (longest gap \(gap)); the latest Live session wins queued reads.")
    }

    /// A delete holds late recognition until SQL decides whether the session still
    /// exists. A failed delete must keep both the old row and the newly heard row;
    /// a successful delete must keep neither.
    @MainActor static func checkDeletionFailurePreservesLateRecognition(directory: URL) async throws {
        for deletionFails in [true, false] {
            let folder = directory.appendingPathComponent(deletionFails ? "delete-fails" : "delete-succeeds")
            let store = try TranscriptStore(directory: folder)
            let gate = CleanupGate()
            gate.close()
            let service = SpeechService(dependencies: .init(
                infer: { _, job, _ in
                    guard !job.samples.isEmpty else { return SpeechOutput(transcripts: [], text: "", processingSeconds: 0) }
                    try await gate.pass()
                    let duration = AudioClock.seconds(samples: job.samples.count)
                    let row = Transcript(sessionID: job.sessionID, startedAt: job.startedAt,
                        startSeconds: job.offset, endSeconds: job.offset + duration,
                        text: "late recognition", mode: "ambient")
                    return SpeechOutput(transcripts: [row], text: row.text, processingSeconds: 0)
                },
                deliver: { _, _ in throw DictationInput.InputError.targetChanged },
                now: Date.init))
            service.keepAudioForSpeakerPass = false
            service.cleanUpTranscriptions = false
            service.beginRecoveryVerification(store: store)
            let session = service.timeline.sessionID
            try store.append(Transcript(id: "seed", sessionID: session,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                startSeconds: 0, endSeconds: 0.5, text: "existing row", mode: "ambient"))
            if deletionFails {
                var db: OpaquePointer?
                let database = folder.appendingPathComponent("transcripts.sqlite3").path
                precondition(sqlite3_open(database, &db) == SQLITE_OK, "Could not open synthetic delete store")
                defer { sqlite3_close(db) }
                let sql = "CREATE TRIGGER block_session_delete BEFORE DELETE ON transcripts " +
                    "WHEN old.session_id = '\(session)' BEGIN SELECT RAISE(ABORT, 'synthetic delete failure'); END"
                precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Could not install synthetic delete failure")
            }
            service.ingestRecoveryVerification(samples: Array(repeating: 1, count: 48_000))
            service.flushRecoveryVerification()
            for _ in 0..<1_000 where !gate.holding { try await Task.sleep(for: .milliseconds(1)) }
            precondition(gate.holding, "Synthetic recognition did not reach the inference gate")
            service.timeline.rotateSession()

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let blocker = service.library.storeExecutor.submit {
                started.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw StoreError.invalid("Timed out holding the synthetic delete queue")
                }
            }
            for _ in 0..<1_000 {
                if isSignaled(started) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let deletion = Task { try await service.deleteSession(session) }
            for _ in 0..<1_000 where service.library.pendingDeletionCount == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(service.library.pendingDeletionCount == 1, "Delete intent was not visible before SQL ran")
            gate.open()
            release.signal()
            try await blocker.value
            let failed: Bool
            do { try await deletion.value; failed = false }
            catch { failed = true }
            precondition(failed == deletionFails, "Synthetic deletion had an unexpected outcome")
            await service.waitForRecoveryVerification()
            await service.library.waitForReads()
            await service.library.storeExecutor.flush()
            let rows = try store.session(id: session)
            if deletionFails {
                precondition(rows.count == 2 && rows.contains(where: { $0.text == "late recognition" }),
                    "A failed delete dropped valid late recognition: \(rows.map(\.text))")
                precondition(!service.library.sessionIsDeleted(session), "A failed delete left a committed tombstone")
            } else {
                precondition(rows.isEmpty, "Late recognition recreated a deleted session: \(rows.map(\.text))")
                precondition(service.library.sessionIsDeleted(session), "A committed delete left no tombstone")
            }
            service.shutdown()
        }
        print("PASS: failed deletion keeps late recognition; successful deletion blocks it.")
    }
}
