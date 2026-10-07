import Foundation
import JotCore

/// Existing same-user feed only. Injected I/O lets tests drive paging and deadlines without capture.
struct ListenCommand {
    var request: (String, [String: Any], Int) throws -> Data = { method, params, timeout in
        try LocalServiceClient().request(method: method, params: params, timeout: timeout)
    }
    var uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var wallTime: () -> Date = { Date() }
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var output: (String) -> Void = { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    func run(_ args: [String]) throws {
        let options = try ListenOptions(args)
        let deadline = options.timeout.map { uptime() + $0 }
        func expired() -> Bool { deadline.map { uptime() >= $0 } ?? false }
        func call(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
            let seconds = deadline.map { max(1, min(30, Int(ceil($0 - uptime())))) } ?? 30
            let data = try request(method, params, seconds)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = object["ok"] as? Bool else { throw ListenError("Invalid Jot response") }
            guard ok else { throw ListenError(object["error"] as? String ?? "Jot request failed") }
            guard let result = object["result"] else { throw ListenError("Missing Jot result") }
            return result
        }
        func page(_ params: [String: Any]) throws -> TranscriptChanges {
            let result = try call("transcripts.since", params)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranscriptChanges.self, from: JSONSerialization.data(withJSONObject: result))
        }
        func emit(_ events: [TranscriptListenEvent]) throws -> Bool {
            for event in events {
                output(try event.line())
                if options.once { return true }
            }
            return false
        }
        do {
            guard !expired() else { return }
            let settings = try call("settings.get") as? [String: Any]
            let configuration = options.configuration(settings?["settings"] as? [[String: Any]] ?? [])
            let subscribedAt = wallTime()
            var current = try page([:]) // omitted cursor subscribes at head
            while current.hasMore, !expired() {
                var params: [String: Any] = ["cursor": current.cursor, "limit": 200]
                if let generation = current.generation { params["generation"] = generation }
                current = try page(params)
            }
            guard !expired() else { return }
            var context: [Transcript] = []
            if configuration.mode == .context {
                // Snapshot after the head: subsequent feed changes reconcile edits/deletes during this read.
                let cutoff = wallTime().addingTimeInterval(-Double(configuration.lookbackMinutes * 60))
                var offset = 0, bytes = 0
                snapshot: while !expired(), context.count < TranscriptListener.maximumRows {
                    let result = try call("transcripts.recent", ["limit": 200, "offset": offset])
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let rows = try decoder.decode([Transcript].self, from: JSONSerialization.data(withJSONObject: result))
                    for row in rows {
                        if row.startedAt.addingTimeInterval(row.endSeconds) < cutoff { break snapshot }
                        bytes += min(row.text.utf8.count, TranscriptListener.maximumRowBytes)
                        if bytes > TranscriptListener.maximumTextBytes { break snapshot }
                        context.append(row)
                        if context.count == TranscriptListener.maximumRows { break snapshot }
                    }
                    if rows.count < 200 { break }
                    offset += rows.count
                }
            }
            guard !expired() else { return }
            var listener = TranscriptListener(configuration: configuration, subscribedAt: subscribedAt)
            listener.seedContext(context)
            var paused = false
            while !expired() {
                var params: [String: Any] = ["cursor": current.cursor, "limit": 200]
                if let generation = current.generation { params["generation"] = generation }
                current = try page(params)
                guard !expired() else { return }
                if try emit(listener.consume(current, at: uptime())) { return }
                if current.reset {
                    current = try page([:]) // drop replay and resubscribe at the new head
                    listener = TranscriptListener(configuration: configuration, subscribedAt: wallTime())
                    continue
                }
                if current.hasMore { continue } // quiet-gap never fires between pages
                let status = try call("speech.status") as? [String: Any]
                guard !expired() else { return }
                let isPaused = status?["mode"] as? String == "paused"
                if isPaused, !paused {
                    if try emit(listener.pause()) { return }
                } else if !isPaused {
                    if try emit(listener.advance(at: uptime())) { return }
                }
                paused = isPaused
                let advertised = current.pollAfterSeconds.isFinite ? current.pollAfterSeconds : TranscriptChanges.caughtUpPollSeconds
                let delay = max(TranscriptChanges.caughtUpPollSeconds, min(60, advertised))
                sleep(deadline.map { max(0, min(delay, $0 - uptime())) } ?? delay)
            }
        } catch {
            if expired() { return }
            throw error
        }
    }
}
