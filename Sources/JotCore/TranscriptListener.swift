import Foundation

/// A bounded, pure follower. Revisions replace rows by identity; they never append a command twice.
/// Call `advance` only after draining all `hasMore` pages, with monotonic arrival time.
public struct TranscriptListener: Sendable {
    public static let maximumRows = 2048
    public static let maximumTextBytes = 131_072
    public static let maximumRowBytes = 8192
    public static let maximumCommandBytes = 32_768
    public static let maximumContextBytes = 32_768
    private struct Key: Hashable, Sendable { var session: String; var id: String }
    private struct Entry: Sendable { var row: Transcript; var triggered = false; var truncated = false }
    private struct Command: Sendable { var anchor: Key; var rows: [Key]; var arrivedAt: Double }
    private struct Emitted: Sendable { var session: String; var start: Date; var end: Date }
    private var emitted: [Emitted] = []
    public static let maximumCommandRows = 256
    private let configuration: TranscriptListenConfiguration
    private var subscribedAt: Date
    private var forgottenThrough = Date.distantPast
    private var entries: [Key: Entry] = [:]
    private var command: Command?
    private var textBytes = 0
    public var retainedRows: Int { entries.count }
    public var retainedTextBytes: Int { textBytes }

    public init(configuration: TranscriptListenConfiguration = .init(), subscribedAt: Date) {
        self.configuration = configuration; self.subscribedAt = subscribedAt
    }

    /// Context snapshot only: historical speech never wakes the follower.
    public mutating func seedContext(_ rows: [Transcript]) {
        for row in rows where row.mode == "ambient" && end(row) <= subscribedAt { put(row, triggered: true) }
        prune()
    }

    public mutating func consume(_ page: TranscriptChanges, at now: Double) -> [TranscriptListenEvent] {
        if page.reset {
            entries.removeAll(); emitted.removeAll(); textBytes = 0; command = nil; forgottenThrough = .distantPast
            return configuration.mode == .all ? [.init(event: "reset")] : []
        }
        var events: [TranscriptListenEvent] = []
        let changes = page.rows.map { ($0.sequence, Optional($0.transcript), Optional<TranscriptDeletion>.none) }
            + page.deleted.map { ($0.sequence, Optional<Transcript>.none, Optional($0)) }
        for (_, row, deleted) in changes.sorted(by: { $0.0 < $1.0 }) {
            if let deleted {
                let key = Key(session: deleted.sessionID, id: deleted.id)
                if let removed = entries.removeValue(forKey: key) { textBytes -= removed.row.text.utf8.count }
                if command?.anchor == key { command = nil }
                else { command?.rows.removeAll { $0 == key } }
                if configuration.mode == .all { events.append(.init(event: "deleted", id: deleted.id, sessionID: deleted.sessionID)) }
                continue
            }
            guard let row else { continue }
            let key = Key(session: row.sessionID, id: row.id)
            for previous in entries.keys.filter({ $0.id == row.id && $0 != key }) {
                if let removed = entries.removeValue(forKey: previous) { textBytes -= removed.row.text.utf8.count }
                if command?.anchor == previous { command = nil }
                else { command?.rows.removeAll { $0 == previous } }
            }
            let existing = entries[key]
            put(row, triggered: existing?.triggered ?? false)
            if configuration.mode == .all {
                events.append(.init(event: "row", text: entries[key]?.row.text, id: row.id,
                                    sessionID: row.sessionID, truncated: entries[key]?.truncated == true ? true : nil, transcript: entries[key]?.row))
                prune(); continue
            }
            guard row.mode == "ambient" else { prune(); continue }
            if command?.rows.contains(key) == true {
                // Rewrites cannot postpone the arrival-gap deadline.
                if let active = command, commandText(active.rows).isEmpty { command = nil }
                prune(); continue
            }
            guard end(row) > subscribedAt, start(row) > forgottenThrough, !alreadyEmitted(row) else { prune(); continue }
            if existing == nil, let active = command, let anchor = entries[active.anchor]?.row {
                if row.sessionID != anchor.sessionID || row.speakerID != anchor.speakerID {
                    if let event = finish() { events.append(event) }
                } else if start(row) >= start(anchor) {
                    command?.rows.append(key); command?.arrivedAt = now; entries[key]?.triggered = true
                    if commandBytes > Self.maximumCommandBytes || (command?.rows.count ?? 0) >= Self.maximumCommandRows {
                        if var event = finish() { event.truncated = true; events.append(event) }
                    }
                    prune(); continue
                }
            }
            if entries[key]?.triggered == false, let wake = wakeEnding(at: key) {
                for member in wake { entries[member]?.triggered = true }
                if configuration.mode == .fast {
                    let text = commandText(wake)
                    rememberEmission(wake)
                    events.append(.init(event: "command", text: text, rowIDs: wake.map(\.id),
                                        truncated: wake.contains { entries[$0]?.truncated == true } ? true : nil))
                } else { command = Command(anchor: wake[0], rows: wake, arrivedAt: now) }
            }
            prune()
        }
        return events
    }

    public mutating func advance(at now: Double) -> [TranscriptListenEvent] {
        guard let command, now - command.arrivedAt >= configuration.quietGap else { return [] }
        return finish().map { [$0] } ?? []
    }

    public mutating func pause() -> [TranscriptListenEvent] {
        var result = finish().map { [$0] } ?? []
        result.append(.init(event: "paused"))
        return result
    }

    private var commandBytes: Int { command?.rows.reduce(0) { $0 + (entries[$1]?.row.text.utf8.count ?? 0) + 1 } ?? 0 }
    private func start(_ row: Transcript) -> Date { row.startedAt.addingTimeInterval(row.startSeconds) }
    private func end(_ row: Transcript) -> Date { row.startedAt.addingTimeInterval(row.endSeconds) }
    private func ordered(_ keys: [Key]) -> [Key] { keys.sorted {
        guard let a = entries[$0]?.row, let b = entries[$1]?.row else { return $0.id < $1.id }
        return start(a) == start(b) ? a.id < b.id : start(a) < start(b)
    } }
    private mutating func put(_ row: Transcript, triggered: Bool) {
        var value = row
        value.text = Self.bounded(row.text, bytes: Self.maximumRowBytes)
        let key = Key(session: row.sessionID, id: row.id)
        textBytes -= entries[key]?.row.text.utf8.count ?? 0
        textBytes += value.text.utf8.count
        entries[key] = Entry(row: value, triggered: triggered, truncated: value.text != row.text)
    }
    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        return String(text.prefix { character in
            used += String(character).utf8.count
            return used <= bytes
        })
    }
    private func wakeRange(in text: String) -> Range<String.Index>? {
        var first: Range<String.Index>?
        for phrase in configuration.wakePhrases {
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+") + "(?![\\p{L}\\p{M}\\p{N}_])"
            guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            if first == nil || match.lowerBound < first!.lowerBound { first = match }
        }
        return first
    }
    /// An alias may straddle two adjacent recognition rows, without joining unrelated speakers.
    private func wakeEnding(at key: Key) -> [Key]? {
        guard let row = entries[key]?.row else { return nil }
        if wakeRange(in: row.text) != nil { return [key] }
        guard configuration.wakePhrases.contains(where: { $0.contains(" ") }) else { return nil }
        let previous = entries.filter { candidate, value in
            candidate != key && !value.triggered && value.row.mode == "ambient" && value.row.sessionID == row.sessionID
                && value.row.speakerID == row.speakerID && start(value.row) < start(row)
                && start(row).timeIntervalSince(end(value.row)) <= configuration.quietGap
                && end(value.row) > subscribedAt
        }.max { start($0.value.row) < start($1.value.row) }
        guard let previous else { return nil }
        let combined = String(previous.value.row.text.suffix(160)) + " " + row.text
        guard let match = wakeRange(in: combined), combined[match].contains(" "),
              match.lowerBound < combined.index(combined.startIndex, offsetBy: String(previous.value.row.text.suffix(160)).count),
              match.upperBound > combined.index(combined.startIndex, offsetBy: String(previous.value.row.text.suffix(160)).count) else { return nil }
        return [previous.key, key]
    }
    private func commandText(_ keys: [Key]) -> String {
        let text = ordered(keys).compactMap { entries[$0]?.row.text }.joined(separator: " ")
        guard let match = wakeRange(in: text) else { return "" }
        return Self.bounded(String(text[match.lowerBound...]), bytes: Self.maximumCommandBytes)
    }
    private mutating func finish() -> TranscriptListenEvent? {
        guard let active = command else { return nil }
        command = nil
        let keys = ordered(active.rows).filter { entries[$0] != nil }
        let text = commandText(keys)
        guard !text.isEmpty else { return nil }
        let anchor = entries[active.anchor]!.row
        var context: [Transcript] = []
        var contextBytes = 0, truncated = keys.contains { entries[$0]?.truncated == true }
        if configuration.mode == .context {
            let before = start(anchor), after = before.addingTimeInterval(-Double(configuration.lookbackMinutes * 60))
            for key in ordered(Array(entries.keys)).reversed() {
                guard let row = entries[key]?.row, row.mode == "ambient", end(row) >= after, start(row) < before,
                      !keys.contains(key) else { continue }
                let bytes = row.text.utf8.count
                guard contextBytes + bytes <= Self.maximumContextBytes, context.count < 200 else { truncated = true; break }
                context.insert(row, at: 0); contextBytes += bytes
            }
        }
        rememberEmission(keys)
        return .init(event: "command", text: text, rowIDs: keys.map(\.id),
                     context: configuration.mode == .context ? context : nil, truncated: truncated ? true : nil)
    }
    private func alreadyEmitted(_ row: Transcript) -> Bool {
        emitted.contains { $0.session == row.sessionID && start(row) >= $0.start && start(row) < $0.end }
    }
    private mutating func rememberEmission(_ keys: [Key]) {
        let rows = keys.compactMap { entries[$0]?.row }
        guard let first = rows.first, let lower = rows.map({ start($0) }).min(), let upper = rows.map({ end($0) }).max() else { return }
        emitted.append(Emitted(session: first.sessionID, start: lower, end: upper))
        if emitted.count > 128 {
            let old = emitted.removeFirst()
            forgottenThrough = max(forgottenThrough, old.end)
        }
    }
    private mutating func prune() {
        guard entries.count > Self.maximumRows || textBytes > Self.maximumTextBytes else { return }
        let protected = Set(command?.rows ?? [])
        for key in ordered(Array(entries.keys)) {
            guard entries.count > Self.maximumRows || retainedTextBytes > Self.maximumTextBytes else { break }
            guard !protected.contains(key), let removed = entries.removeValue(forKey: key) else { continue }
            textBytes -= removed.row.text.utf8.count
            forgottenThrough = max(forgottenThrough, end(removed.row))
        }
    }
}
