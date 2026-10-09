import XCTest
@testable import JotCore

final class TuningLabTests: XCTestCase {
    // MARK: Variants

    func testVariantsParseAndShareOneRecognitionRunWhenOnlyGroupingDiffers() throws {
        let json = """
        [
          {"name": "current", "settings": {}},
          {"name": "steadier", "settings": {"minimumSpeakerTurn": 2.0, "paragraphPause": 2}},
          {"name": "short chunks", "settings": {"chunkMaximumSeconds": 2, "speakerConfidence": 0.7}},
          {"name": "no cleanup", "settings": {"cleanUpTranscriptions": false}}
        ]
        """
        let variants = try LabVariant.parse(Data(json.utf8))
        XCTAssertEqual(variants.map(\.name), ["current", "steadier", "short chunks", "no cleanup"])
        XCTAssertEqual(variants[1].settings[JotSettings.minimumSpeakerTurn], .number(2))
        XCTAssertEqual(variants[3].settings[JotDefaultsKey.cleanUpTranscriptions], .bool(false))
        let runs = LabVariant.recognitionRuns(variants)
        XCTAssertEqual(runs.map { $0.map(\.name) }, [["current", "steadier"], ["short chunks"], ["no cleanup"]])
    }

    func testVariantsRejectUnknownNonTranscriptionDuplicateAndEmptyInput() {
        XCTAssertThrowsError(try LabVariant.parse(Data(#"[{"name": "a", "settings": {"noSuchKey": 1}}]"#.utf8)))
        XCTAssertThrowsError(try LabVariant.parse(Data(#"[{"name": "a", "settings": {"suggestionsEnabled": false}}]"#.utf8)))
        XCTAssertThrowsError(try LabVariant.parse(Data(#"[{"name": "a", "settings": {}}, {"name": "a", "settings": {}}]"#.utf8)))
        XCTAssertThrowsError(try LabVariant.parse(Data(#"[{"name": "", "settings": {}}]"#.utf8)))
        XCTAssertThrowsError(try LabVariant.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try LabVariant.parse(Data(#"{"name": "a"}"#.utf8)))
    }

    func testVariantAppliesOverTheBaseSettingsWithTheSameValidationAsJotSettingsSet() throws {
        let defaults = MemoryDefaults()
        let settings = JotSettings(defaults: defaults)
        let variant = try LabVariant.parse(Data(#"[{"name": "a", "settings": {"chunkMaximumSeconds": 99, "cleanUpTranscriptions": false}}]"#.utf8))[0]
        try variant.apply(to: settings)
        XCTAssertEqual(settings.double(JotSettings.chunkMaximumSeconds), 15, "A number outside the range is clamped, as jot settings set does")
        XCTAssertFalse(settings.bool(JotDefaultsKey.cleanUpTranscriptions))
        let wrongKind = try LabVariant.parse(Data(#"[{"name": "b", "settings": {"cleanUpTranscriptions": "maybe"}}]"#.utf8))[0]
        XCTAssertThrowsError(try wrongKind.apply(to: settings))
    }

    func testARecognitionRunUsesOnlyNonGroupingSettingsSoVariantOrderDoesNotMatter() throws {
        let file = #"[{"name": "a", "settings": {"minimumSpeakerTurn": 0.2, "chunkMaximumSeconds": 4}}, {"name": "b", "settings": {"chunkMaximumSeconds": 4}}]"#
        let variants = try LabVariant.parse(Data(file.utf8))
        XCTAssertEqual(LabVariant.recognitionRuns(variants).count, 1)
        XCTAssertEqual(variants[0].recognitionSettings.settings, variants[1].recognitionSettings.settings)
        XCTAssertEqual(variants[0].recognitionSettings.settings, [JotSettings.chunkMaximumSeconds: .number(4)])
    }

    // MARK: Captions

    func testSRTAndWebVTTCaptionsBecomeCueText() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>Hello</i> there,
        general Kenobi.

        2
        00:00:04,000 --> 00:00:05,000
        {\\an8}You are a bold one.
        """
        let cues = try LabCaptions.parse(srt)
        XCTAssertEqual(cues.map(\.text), ["Hello there, general Kenobi.", "You are a bold one."])
        XCTAssertEqual(cues.map(\.start), [1, 4])
        XCTAssertEqual(cues.map(\.end), [3.5, 5])

        let vtt = """
        WEBVTT

        NOTE written by hand

        00:01.000 --> 00:02.000 align:start
        <v Kim>First line</v>

        intro
        01:00:02.500 --> 01:00:04.000
        Second &amp; last
        """
        let vttCues = try LabCaptions.parse(vtt)
        XCTAssertEqual(vttCues.map(\.text), ["First line", "Second & last"])
        XCTAssertEqual(vttCues.map(\.start), [1, 3602.5])
        XCTAssertThrowsError(try LabCaptions.parse("just some words with no timings"))
    }

    func testVoiceTagsGiveACueItsSpeakerInWebVTTAndSRT() throws {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:02.000
        <v Kim>First line</v>

        00:02.500 --> 00:04.000
        <v.loud Lee &amp; Co>Second</v>
        line

        00:04.500 --> 00:05.000
        <v Kim>Yes.</v> <v Lee>No.</v>

        00:05.500 --> 00:06.000
        <v Kim>Still</v>
        <v Kim>me</v>

        00:07.000 --> 00:08.000
        Nobody tagged this
        """
        let cues = try LabCaptions.parse(vtt)
        XCTAssertEqual(cues.map(\.speaker), ["Kim", "Lee & Co", nil, "Kim", nil], "Two voices in one cue can't be placed in time, so it names none")
        XCTAssertEqual(cues.map(\.text), ["First line", "Second line", "Yes. No.", "Still me", "Nobody tagged this"])
        let srt = try LabCaptions.parse("1\n00:00:00,000 --> 00:00:02,050\n<v Daniel>No, the deadline is Friday.\n")
        XCTAssertEqual(srt, [LabCaptions.Cue(start: 0, end: 2.05, text: "No, the deadline is Friday.", speaker: "Daniel")])
    }

    // MARK: Word error rate

    func testWordErrorRateCountsSubstitutionsDeletionsAndInsertionsIgnoringCaseAndPunctuation() {
        let score = WordErrorRate.score(reference: "The quick brown fox, jumps.", hypothesis: "the quick brawn fox jumps over")
        XCTAssertEqual(score.referenceWords, 5)
        XCTAssertEqual(score.substitutions, 1)
        XCTAssertEqual(score.deletions, 0)
        XCTAssertEqual(score.insertions, 1)
        XCTAssertEqual(score.rate, 0.4, accuracy: 1e-9)
        let dropped = WordErrorRate.score(reference: "one two three four", hypothesis: "one four")
        XCTAssertEqual(dropped.deletions, 2)
        XCTAssertEqual(dropped.rate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(WordErrorRate.score(reference: "", hypothesis: "words").rate, 0)
        XCTAssertEqual(WordErrorRate.score(reference: "it's 5 o'clock", hypothesis: "It's 5 o'clock.").rate, 0)
    }

    // MARK: Speakers

    private func cue(_ start: Double, _ end: Double, _ speaker: String?) -> LabCaptions.Cue {
        LabCaptions.Cue(start: start, end: end, text: "words", speaker: speaker)
    }

    func testSpeakerWordAccuracyPairsEachSpeakerWithOneCaptionVoiceForTheMostWordsRight() throws {
        let captions = [cue(0, 3, "Kim"), cue(3.5, 6, "Lee"), cue(6.5, 7.5, nil), cue(8, 9, "Kim"), cue(8.5, 9.5, "Lee"),
                        cue(10, 12, "Kim"), cue(11, 13, nil)]
        // Each word by the time of its midpoint and the speaker the transcript gave it.
        let heard: [(Double, String?)] = [
            (0.5, "speaker-1"), (1, "speaker-1"), (1.5, "speaker-1"), (2, "speaker-2"), (2.5, "speaker-2"), (2.8, nil),
            (4, "speaker-1"), (4.5, "speaker-1"), (5, "overlap"),
            (3.25, "speaker-1"), (7, "speaker-2"), (8.7, "speaker-1"), (11.5, "speaker-1"),
        ]
        let words = heard.enumerated().map { index, word in
            StoredWord(transcriptID: "r", position: index, word: "w", startSeconds: word.0 - 0.1, endSeconds: word.0 + 0.1, probabilities: [])
        }
        let score = try XCTUnwrap(LabSpeakerScore(words: words, speakers: heard.map(\.1), captions: captions))
        XCTAssertEqual(score.words, 9)
        XCTAssertEqual(score.unscored, 4, "Between cues, in an untagged cue, and where a cue overlaps another voice's or an untagged one")
        XCTAssertEqual(score.unattributed, 2, "No speaker, or overlap, which names no one")
        // speaker-1 heard Kim 3 times and Lee twice; speaker-2 heard Kim twice. Pairing each id with its most frequent voice
        // would give Kim both ids for 5 right; pairing the biggest count first would leave speaker-2 with none.
        XCTAssertEqual(score.pairs, ["speaker-1": "Lee", "speaker-2": "Kim"])
        XCTAssertEqual(score.correct, 4)
        XCTAssertEqual(score.accuracy, 4.0 / 9, accuracy: 1e-9)

        XCTAssertNil(try LabSpeakerScore(words: words, speakers: heard.map(\.1), captions: [cue(0, 10, nil)]), "No caption speakers, no score")
        XCTAssertThrowsError(try LabSpeakerScore(words: words, speakers: [nil], captions: captions))
    }

    func testBestPairingFindsTheLargestOneToOneTotal() {
        XCTAssertEqual(LabSpeakerScore.bestPairing([[10, 9], [9, 0]]), [1, 0])
        XCTAssertEqual(LabSpeakerScore.bestPairing([[5], [7]]), [nil, 0])
        XCTAssertEqual(LabSpeakerScore.bestPairing([[3, 4, 0]]), [1])
        XCTAssertEqual(LabSpeakerScore.bestPairing([]), [])
        func brute(_ gains: [[Int]], _ row: Int = 0, _ used: Set<Int> = []) -> Int {
            guard row < gains.count else { return 0 }
            var best = brute(gains, row + 1, used)
            for column in gains[row].indices where !used.contains(column) {
                best = max(best, gains[row][column] + brute(gains, row + 1, used.union([column])))
            }
            return best
        }
        var seed: UInt64 = 218
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for _ in 0..<200 {
            let rows = 1 + next(6), columns = 1 + next(6)
            let gains = (0..<rows).map { _ in (0..<columns).map { _ in next(4) == 0 ? 0 : next(50) } }
            let pairing = LabSpeakerScore.bestPairing(gains)
            let columnsUsed = pairing.compactMap { $0 }
            XCTAssertEqual(Set(columnsUsed).count, columnsUsed.count, "Each caption voice is paired at most once")
            let total = zip(gains, pairing).reduce(0) { sum, row in sum + (row.1.map { row.0[$0] } ?? 0) }
            XCTAssertEqual(total, brute(gains), "\(gains)")
        }
    }

    // MARK: Rows

    private func words(_ row: String, _ text: String, from start: Double) -> [StoredWord] {
        text.split(separator: " ").enumerated().map { index, word in
            StoredWord(transcriptID: row, position: index, word: String(word), startSeconds: start + Double(index) * 0.5, endSeconds: start + Double(index) * 0.5 + 0.25, probabilities: [])
        }
    }

    func testRowsSplitWhereThePassSpeakerChangesAndKeepLiveSpeakerRawAndCleanedText() throws {
        let stored = words("a", "so um we agree", from: 0) + words("b", "yes we do", from: 3) + words("c", "um", from: 6)
        let rows = [
            // The store returns a cleaned row's cleaned text; its raw text is only in its words.
            Transcript(id: "a", sessionID: "s", startedAt: Date(), startSeconds: 0, endSeconds: 2, text: "So we agree.", speakerID: "speaker-1", mode: "ambient"),
            Transcript(id: "b", sessionID: "s", startedAt: Date(), startSeconds: 3, endSeconds: 4.5, text: "yes we do", speakerID: "speaker-1", mode: "ambient"),
            Transcript(id: "c", sessionID: "s", startedAt: Date(), startSeconds: 6, endSeconds: 6.25, text: "um", speakerID: nil, mode: "ambient")
        ]
        let live: [String?] = ["speaker-1", "speaker-1", "speaker-1", "speaker-1", "speaker-1", "speaker-2", "speaker-2", nil]
        let pass: [String?] = ["speaker-1", "speaker-1", "speaker-1", "speaker-1", "speaker-2", "speaker-2", "speaker-2", nil]
        let result = try LabRows.rows(rows: rows, words: stored, readable: ["a": "So we agree.", "b": "Yes we do.", "c": ""],
            liveSpeakers: live, passSpeakers: pass)
        XCTAssertEqual(result.map(\.rawText), ["so um we agree", "yes we do", "um"])
        XCTAssertEqual(result.map(\.passSpeaker), ["speaker-1", "speaker-2", nil])
        XCTAssertEqual(result.map(\.liveSpeaker), ["speaker-1", "speaker-2", nil], "Live speaker is the one most of the row's words had")
        XCTAssertEqual(result.map(\.cleanedText), ["So we agree.", "Yes we do.", ""])
        XCTAssertEqual(result.map(\.cleanup), [.changed, .unchanged, .removed], "Case and punctuation alone are not a change")

        // Without a pass, the live speakers split the rows, and a row never cleaned says so.
        let livePlan = try LabRows.rows(rows: rows, words: stored, readable: [:], liveSpeakers: live, passSpeakers: nil)
        XCTAssertEqual(livePlan.map(\.rawText), ["so um we agree", "yes", "we do", "um"])
        XCTAssertEqual(livePlan.map(\.passSpeaker), [nil, nil, nil, nil])
        XCTAssertEqual(livePlan.map(\.cleanup), [.noCleanedText, .noCleanedText, .noCleanedText, .noCleanedText])
        XCTAssertEqual(livePlan.map(\.start), [0, 3, 3.5, 6])
    }

    func testParagraphsJoinRowsTheWaySessionsShowsThemAtTheVariantsParagraphPause() {
        let rows = [
            LabRow(start: 0, end: 2.9, liveSpeaker: "speaker-1", passSpeaker: "speaker-1", rawText: "no the deadline", cleanedText: "No, the deadline", cleanup: .changed),
            LabRow(start: 3, end: 4, liveSpeaker: "speaker-1", passSpeaker: "speaker-1", rawText: "is friday", cleanedText: nil, cleanup: .noCleanedText),
            LabRow(start: 5.2, end: 6, liveSpeaker: "speaker-1", passSpeaker: "speaker-1", rawText: "agreed", cleanedText: nil, cleanup: .noCleanedText),
            LabRow(start: 6.1, end: 7, liveSpeaker: "speaker-2", passSpeaker: "speaker-2", rawText: "not at all", cleanedText: "", cleanup: .removed)
        ]
        var tuning = TranscriptionTuning()
        tuning.paragraphPause = 1
        let short = LabRows.paragraphs(rows, tuning: tuning)
        XCTAssertEqual(short.map(\.rawText), ["no the deadline is friday", "agreed", "not at all"])
        XCTAssertEqual(short.map { $0.cleanedText }, ["No, the deadline is friday", nil, ""])
        XCTAssertEqual(short.map(\.cleanup), [.changed, .noCleanedText, .removed])
        XCTAssertEqual(short.map(\.end), [4, 6, 7])
        tuning.paragraphPause = 2
        XCTAssertEqual(LabRows.paragraphs(rows, tuning: tuning).map(\.rawText), ["no the deadline is friday agreed", "not at all"],
            "A longer paragraph pause joins the same speaker across a longer gap, never across a speaker change")
    }

    func testParagraphsAfterAPassShowOnlyPassSpeakersAsTheAppDoes() {
        // The pass left the first row unlabeled; its live id happens to match the next row's pass id, a different voice.
        let rows = [
            LabRow(start: 0, end: 1, liveSpeaker: "speaker-1", passSpeaker: nil, rawText: "hello there", cleanedText: nil, cleanup: .noCleanedText),
            LabRow(start: 1.2, end: 2, liveSpeaker: "speaker-2", passSpeaker: "speaker-1", rawText: "general", cleanedText: nil, cleanup: .noCleanedText)
        ]
        let paragraphs = LabRows.paragraphs(rows, tuning: TranscriptionTuning())
        XCTAssertEqual(paragraphs.map(\.rawText), ["hello there", "general"], "Sessions never merges an unattributed row into a pass speaker's paragraph")
        XCTAssertEqual(paragraphs.map(\.passSpeaker), [nil, "speaker-1"])
        XCTAssertEqual(paragraphs.map(\.liveSpeaker), ["speaker-1", "speaker-2"], "A paragraph keeps its live speaker as recorded")
    }

    // MARK: Report

    func testReportPageEscapesTextAndListsEveryVariant() throws {
        let row = LabRow(start: 61, end: 62.5, liveSpeaker: "speaker-1", passSpeaker: "speaker-2", rawText: "a <b> & c", cleanedText: "A <b> & c.", cleanup: .changed)
        let score = LabScore(raw: WordErrorRate.score(reference: "a b c", hypothesis: "a b c"), cleaned: WordErrorRate.score(reference: "a b c", hypothesis: "a b d"))
        let variants = [
            LabVariantResult(name: "current <x>", settings: [:], recognitionRun: 1, rows: [row], paragraphs: [row], timings: .init(audioSeconds: 90, recognitionSeconds: 5, speakerPassSeconds: 2), score: score, cleanupOutcomes: ["changed": 3, "unchanged": 9]),
            LabVariantResult(name: "steadier", settings: ["minimumSpeakerTurn": .number(2)], recognitionRun: 1, rows: [], timings: .init(audioSeconds: 90, recognitionSeconds: 5, speakerPassSeconds: 2), score: nil)
        ]
        let page = LabReport.html(audioName: "debate.wav", variants: variants)
        XCTAssertTrue(page.contains("current &lt;x&gt;"))
        XCTAssertTrue(page.contains("A &lt;b&gt; &amp; c."))
        XCTAssertFalse(page.contains("<b> &"))
        XCTAssertTrue(page.contains("steadier"))
        XCTAssertTrue(page.contains("minimumSpeakerTurn"))
        XCTAssertTrue(page.contains("1:01"))
        XCTAssertTrue(page.contains("changed 3, unchanged 9"))
        let json = try JSONDecoder().decode([LabVariantResult].self, from: LabReport.json(variants))
        XCTAssertEqual(json, variants)
    }

    func testSpeakerScoresShowInTheReportAndJSONOnlyWhenTheCaptionsNameSpeakers() throws {
        let wer = WordErrorRate.score(reference: "a b c", hypothesis: "a b c")
        let timings = LabVariantResult.Timings(audioSeconds: 90, recognitionSeconds: 5, speakerPassSeconds: 2)
        let plain = LabVariantResult(name: "current", settings: [:], recognitionRun: 1, rows: [], timings: timings, score: LabScore(raw: wer, cleaned: wer))
        let plainPage = LabReport.html(audioName: "a.wav", variants: [plain])
        XCTAssertFalse(plainPage.contains("Speaker words right"))
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: LabReport.json([plain])) as? [[String: Any]])
        XCTAssertEqual((plainJSON[0]["score"] as? [String: Any]).map { Set($0.keys) }, ["raw", "cleaned"])

        let words = [StoredWord(transcriptID: "r", position: 0, word: "a", startSeconds: 0, endSeconds: 0.5, probabilities: [])]
        var scored = plain
        scored.score?.liveSpeakers = try XCTUnwrap(LabSpeakerScore(words: words, speakers: ["speaker-1"], captions: [cue(0, 1, "Kim")]))
        let page = LabReport.html(audioName: "a.wav", variants: [scored, plain])
        XCTAssertTrue(page.contains("<th>WER cleaned</th><th>Speaker words right</th><th>Cleanup phrases</th>"))
        XCTAssertTrue(page.contains("live 100.0% <span class=\"meta\">(1 of 1 words, 0 unattributed)</span>"))
        XCTAssertEqual(try JSONDecoder().decode([LabVariantResult].self, from: LabReport.json([scored])), [scored])
    }
}
