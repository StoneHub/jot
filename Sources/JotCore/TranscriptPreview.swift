import Foundation

/// The transcript preview Vorssaint's Island may show: the last row Jot saved while listening, on one line, with its
/// speaker's name when Jot knows it. Only the bundled helper can read it (`speech.preview`), and only while
/// `shareTranscriptPreview` is on.
public enum TranscriptPreview {
    public static let maximumLength = 180
    /// A speaker name longer than this is cut, so the words keep most of the room.
    static let maximumLabelLength = 40

    /// The row's words on one line, prefixed `Name: ` when a name is given. A long row keeps its newest words after
    /// a leading ellipsis. Nil when the row has no words.
    public static func text(_ words: String, speaker: String?) -> String? {
        let line = words.split(whereSeparator: { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
        }).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        let name = speaker.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
        let label = name.isEmpty ? "" : String(name.prefix(maximumLabelLength)) + ": "
        let room = maximumLength - label.count
        return label + (line.count <= room ? line : "…" + String(line.suffix(room - 1)))
    }
}
