import Foundation

/// A fixed set of recordings `jot lab --set` scores together: a folder holding `set.json`, the audio files and their
/// captions. The folder stays outside any git repository, because the recordings and their captions are private; the
/// repository holds only the generator for the synthetic set and the scores, which are numbers.
public struct LabSet: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// A short id, also the name of the item's output folder.
        public var name: String
        /// Relative to the set folder.
        public var audio: String
        /// Relative to the set folder; SubRip or WebVTT, with voice tags when speakers should be scored.
        public var captions: String

        public init(name: String, audio: String, captions: String) { self.name = name; self.audio = audio; self.captions = captions }
    }

    public var name: String
    public var items: [Item]

    public init(name: String, items: [Item]) { self.name = name; self.items = items }

    public static let manifest = "set.json"

    /// Reads a set folder's manifest and checks that every item's files are there and the names are usable as folder names.
    public static func load(_ folder: URL) throws -> LabSet {
        let file = folder.appendingPathComponent(manifest)
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw LabError.invalid("\(folder.path) has no \(manifest); make one with scripts/make-lab-set.py or by hand.")
        }
        return try parse(data, folder: folder)
    }

    public static func parse(_ data: Data, folder: URL) throws -> LabSet {
        let set: LabSet
        do { set = try JSONDecoder().decode(LabSet.self, from: data) }
        catch { throw LabError.invalid("\(manifest) must be {\"name\": …, \"items\": [{\"name\", \"audio\", \"captions\"}]}: \(error.localizedDescription)") }
        guard !set.name.isEmpty, !set.items.isEmpty else { throw LabError.invalid("The set needs a name and at least one item.") }
        var names: Set<String> = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for item in set.items {
            guard !item.name.isEmpty, item.name.count <= 64, item.name.unicodeScalars.allSatisfy(allowed.contains) else {
                throw LabError.invalid("Item name \(item.name) must be 1 to 64 letters, digits, - or _.")
            }
            guard names.insert(item.name).inserted else { throw LabError.invalid("Two items are named \(item.name).") }
            for (what, path) in [("audio", item.audio), ("captions", item.captions)] {
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
                    throw LabError.invalid("\(item.name): \(what) must be a path inside the set folder, not \(path).")
                }
                guard FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(path).path) else {
                    throw LabError.invalid("\(item.name): cannot read \(what) at \(folder.appendingPathComponent(path).path).")
                }
            }
        }
        return set
    }

    public func audio(_ item: Item, in folder: URL) -> URL { folder.appendingPathComponent(item.audio) }
    public func captions(_ item: Item, in folder: URL) -> URL { folder.appendingPathComponent(item.captions) }
}

/// What a set run leaves for comparison: every item's and variant's scores and timings, and nothing from the recordings.
/// `scripts/compare-lab-scores.py` reads two of these.
public struct LabSetScores: Codable, Sendable, Equatable {
    public struct Variant: Codable, Sendable, Equatable {
        public var name: String
        public var rows: Int
        public var paragraphs: Int
        public var raw: WordErrorRate.Score
        public var cleaned: WordErrorRate.Score
        /// Share of scored words whose speaker matched the captions; nil when the captions name no speakers.
        public var liveSpeakerAccuracy: Double?
        public var passSpeakerAccuracy: Double?
        public var timings: LabVariantResult.Timings
        /// Process CPU time of the recognition run and the speaker pass, per minute of audio.
        public var cpuSecondsPerAudioMinute: Double

        public init(_ result: LabVariantResult) throws {
            guard let score = result.score else { throw LabError.invalid("\(result.name) has no score; every set item needs captions.") }
            name = result.name
            rows = result.rows.count
            paragraphs = result.paragraphs.count
            raw = score.raw
            cleaned = score.cleaned
            liveSpeakerAccuracy = score.liveSpeakers?.accuracy
            passSpeakerAccuracy = score.passSpeakers?.accuracy
            timings = result.timings
            let minutes = result.timings.audioSeconds / 60
            cpuSecondsPerAudioMinute = minutes > 0 ? (result.timings.cpuSeconds + result.timings.speakerPassCPUSeconds) / minutes : 0
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var audioSeconds: Double
        public var variants: [Variant]

        public init(name: String, results: [LabVariantResult]) throws {
            self.name = name
            audioSeconds = results.first?.timings.audioSeconds ?? 0
            variants = try results.map(Variant.init)
        }
    }

    public var set: String
    public var jotVersion: String
    public var createdAt: Date
    public var items: [Item]

    public init(set: String, jotVersion: String = JotVersion.current, createdAt: Date = Date(), items: [Item]) {
        self.set = set; self.jotVersion = jotVersion; self.createdAt = createdAt; self.items = items
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// One line per item and variant, for the terminal and the PR.
    public func table() -> String {
        var lines = ["| Item | Variant | WER raw | S / D / I | WER cleaned | Speakers live / pass | CPU s per audio min |",
                     "| --- | --- | --- | --- | --- | --- | --- |"]
        for item in items {
            for variant in item.variants {
                let speakers = [variant.liveSpeakerAccuracy, variant.passSpeakerAccuracy].map { $0.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
                lines.append(String(format: "| %@ | %@ | %.1f%% | %d / %d / %d | %.1f%% | %@ / %@ | %.1f |", item.name, variant.name,
                    variant.raw.rate * 100, variant.raw.substitutions, variant.raw.deletions, variant.raw.insertions,
                    variant.cleaned.rate * 100, speakers[0], speakers[1], variant.cpuSecondsPerAudioMinute))
            }
        }
        return lines.joined(separator: "\n")
    }
}
