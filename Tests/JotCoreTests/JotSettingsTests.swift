import XCTest
@testable import JotCore

/// Every test runs against its own UserDefaults suite, never the app's.
final class JotSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "JotSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func legacyTuning(_ json: String) { defaults.set(Data(json.utf8), forKey: JotDefaultsKey.transcriptionTuning) }

    func testFreshInstallReadsCodeDefaultsAndSavesNothing() {
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.tuning, TranscriptionTuning())
        XCTAssertTrue(settings.bool(JotDefaultsKey.cleanUpTranscriptions))
        XCTAssertFalse(settings.bool(JotDefaultsKey.cleanUpDictation))
        XCTAssertEqual(settings.int(JotDefaultsKey.newSessionAfterSilence), SessionSplit.defaultMinutes)
        XCTAssertEqual(settings.int(JotDefaultsKey.recoveryLookbackSeconds), 120)
        for definition in JotSettings.definitions { XCTAssertFalse(settings.isChanged(definition.key), definition.key) }
    }

    /// Monroe's install: a tuning blob saved when one slider moved, plus per-key settings the old code wrote on every change.
    func testExistingPreferencesCarryOverOnce() throws {
        legacyTuning(#"{"speakerConfidence": 0.75, "minimumSpeakerTurn": 1.2, "paragraphPause": 1.5, "hideFillerRows": true}"#)
        defaults.set(true, forKey: JotDefaultsKey.cleanUpTranscriptions)      // the default, saved by a toggle back
        defaults.set(true, forKey: JotDefaultsKey.cleanUpDictation)           // changed
        defaults.set(30, forKey: JotDefaultsKey.newSessionAfterSilence)       // changed
        defaults.set(false, forKey: JotDefaultsKey.suggestionMeetingContext)  // the default
        defaults.set(true, forKey: JotDefaultsKey.fnRequested)                // not a setting; untouched

        let settings = JotSettings(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: JotDefaultsKey.transcriptionTuning), "The blob is gone")
        XCTAssertEqual(settings.double(JotSettings.speakerConfidence), 0.75, accuracy: 0.0001)
        XCTAssertTrue(settings.isChanged(JotSettings.speakerConfidence))
        for key in [JotSettings.minimumSpeakerTurn, JotSettings.paragraphPause, JotSettings.hideFillerRows] {
            XCTAssertFalse(settings.isChanged(key), "\(key) held its default, so it follows the default from now on")
        }
        XCTAssertTrue(settings.bool(JotDefaultsKey.cleanUpTranscriptions))
        XCTAssertFalse(settings.isChanged(JotDefaultsKey.cleanUpTranscriptions))
        XCTAssertFalse(settings.isChanged(JotDefaultsKey.suggestionMeetingContext))
        XCTAssertTrue(settings.bool(JotDefaultsKey.cleanUpDictation))
        XCTAssertEqual(settings.int(JotDefaultsKey.newSessionAfterSilence), 30)
        XCTAssertTrue(defaults.bool(forKey: JotDefaultsKey.fnRequested))
        XCTAssertEqual(defaults.integer(forKey: JotSettings.revisionKey), JotSettings.revision)

        // A second launch changes nothing, including a default a user set on purpose afterwards.
        settings.set(JotSettings.paragraphPause, 2.0)
        defaults.set(true, forKey: JotDefaultsKey.cleanUpTranscriptions)
        let relaunched = JotSettings(defaults: defaults)
        XCTAssertEqual(relaunched.double(JotSettings.paragraphPause), 2.0, accuracy: 0.0001)
        XCTAssertEqual(relaunched.double(JotSettings.speakerConfidence), 0.75, accuracy: 0.0001)
        XCTAssertTrue(relaunched.isChanged(JotDefaultsKey.cleanUpTranscriptions), "Normalizing defaults runs only on the first launch")
    }

    func testUnreadableBlobIsDroppedWithoutChangingAnything() {
        legacyTuning("not json")
        let settings = JotSettings(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: JotDefaultsKey.transcriptionTuning))
        XCTAssertEqual(settings.tuning, TranscriptionTuning())
    }

    func testBlobMissingNewerFieldsKeepsWhatItHas() {
        legacyTuning(#"{"speakerConfidence": 0.5, "paragraphPause": 9}"#)
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.double(JotSettings.speakerConfidence), 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.double(JotSettings.paragraphPause), 2.5, accuracy: 0.0001, "Carried values are bounded")
        XCTAssertFalse(settings.isChanged(JotSettings.minimumSpeakerTurn))
    }

    func testSettingTheDefaultRemovesTheKeyAndResetFollowsTheDefault() throws {
        let settings = JotSettings(defaults: defaults)
        settings.set(JotDefaultsKey.cleanUpDictation, true)
        XCTAssertTrue(settings.isChanged(JotDefaultsKey.cleanUpDictation))
        settings.set(JotDefaultsKey.cleanUpDictation, false)
        XCTAssertFalse(settings.isChanged(JotDefaultsKey.cleanUpDictation))
        settings.set(JotSettings.minimumSpeakerTurn, 0.4)
        try settings.reset(JotSettings.minimumSpeakerTurn)
        XCTAssertFalse(settings.isChanged(JotSettings.minimumSpeakerTurn))
        XCTAssertEqual(settings.double(JotSettings.minimumSpeakerTurn), 1.2, accuracy: 0.0001)
        XCTAssertThrowsError(try settings.reset("bogus")) { XCTAssertEqual($0 as? JotSettingsError, .unknown("bogus")) }
    }

    /// silenceLevel defaults to 0.002 over 0.0005...0.02: a change of 5% is a real change, while slider noise is not.
    func testASmallValueNearItsDefaultStillCounts() throws {
        let settings = JotSettings(defaults: defaults)
        settings.set(JotSettings.silenceLevel, 0.00195)
        XCTAssertTrue(settings.isChanged(JotSettings.silenceLevel))
        XCTAssertEqual(settings.double(JotSettings.silenceLevel), 0.00195)
        settings.set(JotSettings.silenceLevel, 0.002 + 1e-12)
        XCTAssertFalse(settings.isChanged(JotSettings.silenceLevel), "Floating-point noise is the default")
        XCTAssertNil(defaults.object(forKey: JotSettings.silenceLevel))
    }

    func testTuningWritesOnlyTheValuesThatDiffer() {
        let settings = JotSettings(defaults: defaults)
        var tuning = TranscriptionTuning()
        tuning.paragraphPause = 0.8
        settings.setTuning(tuning)
        XCTAssertEqual(settings.tuning, tuning)
        XCTAssertTrue(settings.isChanged(JotSettings.paragraphPause))
        for key in [JotSettings.speakerConfidence, JotSettings.minimumSpeakerTurn, JotSettings.hideFillerRows] { XCTAssertFalse(settings.isChanged(key), key) }
    }

    func testRawValuesFromTheCommandLine() throws {
        let settings = JotSettings(defaults: defaults)
        try settings.set(JotDefaultsKey.cleanUpDictation, raw: "on")
        XCTAssertTrue(settings.bool(JotDefaultsKey.cleanUpDictation))
        try settings.set(JotDefaultsKey.cleanUpDictation, raw: NSNumber(value: false))
        XCTAssertFalse(settings.bool(JotDefaultsKey.cleanUpDictation))
        try settings.set(JotDefaultsKey.newSessionAfterSilence, raw: "10")
        XCTAssertEqual(settings.int(JotDefaultsKey.newSessionAfterSilence), 10)
        try settings.set(JotSettings.paragraphPause, raw: "9")
        XCTAssertEqual(settings.double(JotSettings.paragraphPause), 2.5, accuracy: 0.0001, "Numbers are clamped to their range")
        try settings.set(JotDefaultsKey.recoveryLookbackSeconds, raw: 5)
        XCTAssertEqual(settings.int(JotDefaultsKey.recoveryLookbackSeconds), 15)

        XCTAssertThrowsError(try settings.set(JotDefaultsKey.newSessionAfterSilence, raw: "12")) {
            XCTAssertEqual($0 as? JotSettingsError, .invalid(JotDefaultsKey.newSessionAfterSilence, "one of 0, 10, 15, 30"))
        }
        XCTAssertThrowsError(try settings.set(JotDefaultsKey.cleanUpDictation, raw: "maybe"))
        XCTAssertThrowsError(try settings.set(JotDefaultsKey.recoveryLookbackSeconds, raw: "1.5"))
        XCTAssertThrowsError(try settings.set(JotDefaultsKey.recoveryLookbackSeconds, raw: NSNumber(value: true)))
        XCTAssertThrowsError(try settings.set("bogus", raw: "1")) { XCTAssertEqual($0 as? JotSettingsError, .unknown("bogus")) }
    }

    func testOutOfRangeStoredValuesReadAsBounded() {
        defaults.set(99, forKey: JotDefaultsKey.newSessionAfterSilence)
        defaults.set(5_000, forKey: JotDefaultsKey.recoveryLookbackSeconds)
        defaults.set(5.0, forKey: JotSettings.speakerConfidence)
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.int(JotDefaultsKey.newSessionAfterSilence), SessionSplit.defaultMinutes, "Not one of the choices")
        XCTAssertEqual(settings.int(JotDefaultsKey.recoveryLookbackSeconds), 120, "Outside the range")
        XCTAssertEqual(settings.double(JotSettings.speakerConfidence), 0.9, accuracy: 0.0001, "Clamped to its range")
    }

    /// A build that lists a key under a new revision clears it once; the next launch of the same build keeps what the user sets again.
    func testRevisionResetsAListedKeyOnce() {
        let settings = JotSettings(defaults: defaults)
        settings.set(JotSettings.paragraphPause, 2.0)
        settings.set(JotDefaultsKey.cleanUpDictation, true)
        let resets = [JotSettings.revision + 1: [JotSettings.paragraphPause]]
        settings.applyRevisions(resets, through: JotSettings.revision + 1)
        XCTAssertFalse(settings.isChanged(JotSettings.paragraphPause))
        XCTAssertTrue(settings.isChanged(JotDefaultsKey.cleanUpDictation), "Keys the revision does not list stay")
        settings.set(JotSettings.paragraphPause, 2.0)
        settings.applyRevisions(resets, through: JotSettings.revision + 1)
        XCTAssertTrue(settings.isChanged(JotSettings.paragraphPause), "The same revision does not reset twice")
    }

    func testTextSettingRefusesEmptyAndOverlongText() throws {
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.text(JotSettings.cleanupInstructions), JotSettings.defaultCleanupInstructions)
        try settings.set(JotSettings.cleanupInstructions, raw: "Fix punctuation only.")
        XCTAssertEqual(settings.text(JotSettings.cleanupInstructions), "Fix punctuation only.")
        XCTAssertThrowsError(try settings.set(JotSettings.cleanupInstructions, raw: "  "))
        XCTAssertThrowsError(try settings.set(JotSettings.cleanupInstructions, raw: String(repeating: "a", count: 4001)))
        XCTAssertThrowsError(try settings.set(JotSettings.cleanupInstructions, raw: 5))
        XCTAssertEqual(settings.text(JotSettings.cleanupInstructions), "Fix punctuation only.", "A refused value leaves the saved one")
        try settings.set(JotSettings.cleanupInstructions, JotSettings.defaultCleanupInstructions)
        XCTAssertFalse(settings.isChanged(JotSettings.cleanupInstructions))
    }

    func testPipelineSettingsDefaultToTheFormerConstants() {
        let settings = JotSettings(defaults: defaults)
        XCTAssertEqual(settings.double(JotSettings.chunkMaximumSeconds), 3)
        XCTAssertEqual(settings.double(JotSettings.chunkSilenceSeconds), 0.7)
        XCTAssertEqual(settings.double(JotSettings.silenceLevel), 0.002)
        XCTAssertEqual(settings.double(JotSettings.speechGate), 0.2)
        XCTAssertEqual(settings.double(JotSettings.phrasePause), PhraseCleanup.Limits().pauseSeconds)
        XCTAssertEqual(settings.double(JotSettings.phraseMaximumSeconds), PhraseCleanup.Limits().maximumSeconds)
        XCTAssertEqual(settings.int(JotSettings.phraseMinimumWords), PhraseCleanup.Limits().minimumSentenceWords)
        XCTAssertEqual(settings.int(JotSettings.cleanupMaximumTokens), 1200)
    }

    func testReportListsEverySettingOnce() {
        let report = JotSettings(defaults: defaults).report()
        let keys = report.compactMap { $0["key"] as? String }
        XCTAssertEqual(keys, JotSettings.definitions.map(\.key))
        XCTAssertEqual(Set(keys).count, keys.count)
        let split = report.first { $0["key"] as? String == JotDefaultsKey.newSessionAfterSilence }
        XCTAssertEqual(split?["choices"] as? [Int], SessionSplit.choices)
    }
}
