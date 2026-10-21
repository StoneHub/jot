import Foundation

/// The versioned file `jot export <session-id> --file` writes: one session's spoken rows on the session's clock, for
/// Jot for Android and other tools to read. docs/SHARED-CONTRACT.md is its spec. Session and row ids stay on this Mac.
public enum SessionFile {
    public static let formatName = "jot.session"
    public static let currentVersion = 1

    public struct Row: Codable, Equatable, Sendable {
        /// Seconds from the file's `startedAt`, to the millisecond.
        public var start: Double
        public var end: Double
        public var text: String
        /// "ambient" for listening, "dictation" for a held dictation.
        public var mode: String
        /// The session's own speaker grouping, such as "speaker-1" or "overlap"; absent when no speaker was found.
        public var speaker: String?
        /// The name a person gave that speaker.
        public var speakerName: String?

        public init(start: Double, end: Double, text: String, mode: String, speaker: String? = nil, speakerName: String? = nil) {
            self.start = start; self.end = end; self.text = text; self.mode = mode; self.speaker = speaker; self.speakerName = speakerName
        }
    }

    public struct Contents: Codable, Equatable, Sendable {
        public var format = SessionFile.formatName
        public var version = SessionFile.currentVersion
        public var title: String?
        /// Whole seconds, UTC.
        public var startedAt: Date
        public var rows: [Row]

        public init(title: String?, startedAt: Date, rows: [Row]) {
            self.title = title; self.startedAt = startedAt; self.rows = rows
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notASessionFile, newerVersion(Int), unreadableRows
        public var errorDescription: String? {
            switch self {
            case .notASessionFile: "That file is not a Jot session file."
            case .newerVersion(let version): "That file uses session version \(version), which this Jot cannot read. Update Jot to read it."
            case .unreadableRows: "The rows in that file could not be read."
            }
        }
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    /// Rows that cleanup emptied are left out and continuations are folded, as in the Markdown export, but rows are not
    /// merged into paragraphs, so a reader can merge them its own way.
    public static func contents(session: TranscriptSession, rows: [Transcript]) -> Contents {
        let start = Date(timeIntervalSince1970: session.startedAt.timeIntervalSince1970.rounded(.down))
        func offset(_ row: Transcript, _ seconds: Double) -> Double {
            (max(0, row.startedAt.timeIntervalSince(start) + seconds) * 1000).rounded() / 1000
        }
        let spoken = TranscriptGrouping.foldContinuations(rows.filter(TranscriptExport.isSpoken))
        return Contents(title: session.title, startedAt: start, rows: spoken.map { row in
            let name = row.speakerLabel.flatMap { $0.isEmpty ? nil : $0 }
            return Row(start: offset(row, row.startSeconds), end: max(offset(row, row.startSeconds), offset(row, row.endSeconds)),
                       text: row.text, mode: row.mode, speaker: row.speakerID, speakerName: name)
        })
    }

    public static func encode(_ contents: Contents) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(contents) + Data("\n".utf8)
    }

    /// Reads a file of this version or an earlier one, refusing a newer version rather than reading it in part.
    public static func decode(_ data: Data) throws -> Contents {
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == formatName,
              let version = header.version, version >= 1 else { throw Failure.notASessionFile }
        guard version <= currentVersion else { throw Failure.newerVersion(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Contents.self, from: data) }
        catch { throw Failure.unreadableRows }
    }
}
