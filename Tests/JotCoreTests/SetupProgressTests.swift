import XCTest
@testable import JotCore

/// Every test runs against its own UserDefaults suite and temporary directory, never the app's.
final class SetupProgressTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "SetupProgressTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func createDatabase() {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("transcripts.sqlite3").path, contents: Data())
    }

    private let ready = SetupReadiness(modelsReady: true, microphoneAllowed: true, accessibilityAllowed: true)

    func testFreshInstallIsOfferedSetupAndKeepsItAcrossRelaunches() {
        let first = SetupProgress.atLaunch(defaults: defaults, directory: directory)
        XCTAssertEqual(first.status, .inProgress)
        XCTAssertTrue(first.offeredAtLaunch)
        XCTAssertEqual(defaults.string(forKey: JotDefaultsKey.setupStatus), "inProgress", "The decision is saved at once")
        XCTAssertNil(first.step, "Nothing has been shown yet")
        XCTAssertEqual(first.resumeStep(SetupReadiness(modelsReady: false, microphoneAllowed: false, accessibilityAllowed: false)), .welcome)

        // The first launch opened the store, so the database now exists; an unfinished setup still opens after a restart.
        createDatabase()
        defaults.set(true, forKey: JotDefaultsKey.modelsPrepared)
        let relaunched = SetupProgress.atLaunch(defaults: defaults, directory: directory)
        XCTAssertEqual(relaunched.status, .inProgress)
        XCTAssertTrue(relaunched.offeredAtLaunch)
    }

    func testExistingHistoryIsAnExistingInstallAndNeverOffered() {
        createDatabase()
        let progress = SetupProgress.atLaunch(defaults: defaults, directory: directory)
        XCTAssertEqual(progress.status, .existingInstall)
        XCTAssertFalse(progress.offeredAtLaunch)
        XCTAssertEqual(progress.resumeStep(ready), .summary, "Opened by hand, it shows the readiness summary")
        XCTAssertEqual(SetupProgress.atLaunch(defaults: defaults, directory: directory).status, .existingInstall)
    }

    func testEachEarlierPreferenceMarksAnExistingInstall() {
        for key in SetupProgress.earlierUseKeys {
            let name = "SetupProgressTests.key.\(UUID().uuidString)"
            let suite = UserDefaults(suiteName: name)!
            defer { suite.removePersistentDomain(forName: name) }
            suite.set(false, forKey: key)
            XCTAssertEqual(SetupProgress.atLaunch(defaults: suite, directory: directory).status, .existingInstall, key)
        }
    }

    func testSettingsJotWritesOnEveryLaunchAreNotEvidence() {
        _ = JotSettings(defaults: defaults)
        XCTAssertNotNil(defaults.object(forKey: JotSettings.revisionKey), "JotSettings records its revision on first use")
        XCTAssertEqual(SetupProgress.atLaunch(defaults: defaults, directory: directory).status, .inProgress)
    }

    func testFinishedAndDeferredSetupStayClosedAtLaunch() {
        for status in [SetupProgress.Status.completed, .deferred] {
            SetupProgress(status: status, step: .intelligence).save(to: defaults)
            let progress = SetupProgress.atLaunch(defaults: defaults, directory: directory)
            XCTAssertEqual(progress.status, status)
            XCTAssertFalse(progress.offeredAtLaunch, status.rawValue)
        }
    }

    func testResumeReturnsToTheLastPageWhileItsRequirementsHold() {
        let progress = SetupProgress(status: .inProgress, step: .intelligence)
        XCTAssertEqual(progress.resumeStep(ready), .intelligence)
    }

    func testResumeGoesBackToTheEarliestUnmetRequirement() {
        let progress = SetupProgress(status: .inProgress, step: .summary)
        XCTAssertEqual(progress.resumeStep(SetupReadiness(modelsReady: false, microphoneAllowed: false, accessibilityAllowed: false)), .models,
                       "An interrupted download comes first")
        XCTAssertEqual(progress.resumeStep(SetupReadiness(modelsReady: true, microphoneAllowed: false, accessibilityAllowed: false)), .microphone,
                       "A denied microphone")
        XCTAssertEqual(progress.resumeStep(SetupReadiness(modelsReady: true, microphoneAllowed: true, accessibilityAllowed: false)), .dictation,
                       "Accessibility is asked on the dictation page")
    }

    func testResumeNeverSkipsAheadOfThePageLastShown() {
        let progress = SetupProgress(status: .inProgress, step: .welcome)
        XCTAssertEqual(progress.resumeStep(SetupReadiness(modelsReady: false, microphoneAllowed: false, accessibilityAllowed: true)), .welcome)
    }

    func testFinishedSetupReopensAtTheSummaryUnlessAPermissionWasRevoked() {
        let progress = SetupProgress(status: .completed)
        XCTAssertEqual(progress.resumeStep(ready), .summary)
        XCTAssertEqual(progress.resumeStep(SetupReadiness(modelsReady: true, microphoneAllowed: true, accessibilityAllowed: false)), .dictation)
    }

    func testProgressRoundTripsAndUnknownValuesReadAsAbsent() {
        let saved = SetupProgress(status: .deferred, step: .dictation)
        saved.save(to: defaults)
        XCTAssertEqual(SetupProgress(defaults: defaults), saved)

        defaults.set("someday", forKey: JotDefaultsKey.setupStatus)
        defaults.set(99, forKey: JotDefaultsKey.setupStep)
        XCTAssertEqual(SetupProgress(defaults: defaults), SetupProgress())
        createDatabase()
        XCTAssertEqual(SetupProgress.atLaunch(defaults: defaults, directory: directory).status, .existingInstall,
                       "An unreadable status is decided again from what is on disk")

        SetupProgress().save(to: defaults)
        XCTAssertNil(defaults.object(forKey: JotDefaultsKey.setupStatus))
        XCTAssertNil(defaults.object(forKey: JotDefaultsKey.setupStep))
    }

    func testStepsRunInOrderWithoutGaps() {
        XCTAssertEqual(SetupStep.allCases.first, .welcome)
        XCTAssertEqual(SetupStep.allCases.last, .summary)
        XCTAssertNil(SetupStep.welcome.previous)
        XCTAssertNil(SetupStep.summary.next)
        for step in SetupStep.allCases.dropLast() { XCTAssertEqual(step.next?.previous, step) }
    }
}
