import Foundation

/// First-run setup's pages, in order. Microphone access is asked on the microphone page and Accessibility on the dictation page, where each is needed.
public enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, models, microphone, dictation, intelligence, summary

    public var title: String {
        switch self {
        case .welcome: "Welcome to Jot"
        case .models: "Speech models"
        case .microphone: "Microphone"
        case .dictation: "Try dictation"
        case .intelligence: "Apple Intelligence"
        case .summary: "Summary"
        }
    }

    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The live state behind the pages that have a requirement. Setup keeps no copy of it: the window reads the service each time.
public struct SetupReadiness: Equatable, Sendable {
    public var modelsReady: Bool
    public var microphoneAllowed: Bool
    public var accessibilityAllowed: Bool

    public init(modelsReady: Bool, microphoneAllowed: Bool, accessibilityAllowed: Bool) {
        self.modelsReady = modelsReady; self.microphoneAllowed = microphoneAllowed; self.accessibilityAllowed = accessibilityAllowed
    }

    /// The earliest page whose requirement is unmet now, such as a permission revoked since setup or a download that stopped.
    public var firstUnmet: SetupStep? {
        if !modelsReady { return .models }
        if !microphoneAllowed { return .microphone }
        if !accessibilityAllowed { return .dictation }
        return nil
    }
}

/// Whether launch offers setup, and where setup opens. Two UserDefaults keys hold it; models, permissions and settings stay where they already live.
public struct SetupProgress: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// Offered and not finished: each launch opens it again where it left off.
        case inProgress
        /// The user chose to finish later. Setup opens only when asked.
        case deferred
        case completed
        /// Jot had history or preferences before this build; setup is never offered at launch.
        case existingInstall
    }

    public var status: Status?
    /// The page last shown.
    public var step: SetupStep?

    public init(status: Status? = nil, step: SetupStep? = nil) {
        self.status = status; self.step = step
    }

    /// Unknown stored values read as absent.
    public init(defaults: UserDefaults) {
        status = defaults.string(forKey: JotDefaultsKey.setupStatus).flatMap(Status.init(rawValue:))
        step = (defaults.object(forKey: JotDefaultsKey.setupStep) as? Int).flatMap(SetupStep.init(rawValue:))
    }

    public func save(to defaults: UserDefaults) {
        if let status { defaults.set(status.rawValue, forKey: JotDefaultsKey.setupStatus) }
        else { defaults.removeObject(forKey: JotDefaultsKey.setupStatus) }
        if let step { defaults.set(step.rawValue, forKey: JotDefaultsKey.setupStep) }
        else { defaults.removeObject(forKey: JotDefaultsKey.setupStep) }
    }

    /// Only an unfinished setup opens at launch. Finished, deferred and existing installs open it from the Setup page or the menu.
    public var offeredAtLaunch: Bool { status == .inProgress }

    /// The page last shown, or the summary once setup is done, but never past a page whose requirement is unmet now.
    public func resumeStep(_ readiness: SetupReadiness) -> SetupStep {
        let saved = step ?? (status == .completed || status == .existingInstall ? .summary : .welcome)
        guard let unmet = readiness.firstUnmet else { return saved }
        return min(saved, unmet)
    }

    /// Call at launch before the transcript store opens, since opening creates its file. The first launch of a build with setup decides once
    /// and saves it: an install with history or Jot preferences is existing; anything else is offered setup.
    public static func atLaunch(defaults: UserDefaults, directory: URL) -> SetupProgress {
        var progress = SetupProgress(defaults: defaults)
        guard progress.status == nil else { return progress }
        progress.status = hasEarlierInstall(defaults: defaults, directory: directory) ? .existingInstall : .inProgress
        progress.save(to: defaults)
        return progress
    }

    /// Keys only an earlier run of Jot writes: loaded models, a Pause, the Dictation switch, a shortcut, a microphone or vocabulary.
    static let earlierUseKeys = [JotDefaultsKey.modelsPrepared, JotDefaultsKey.servicePaused, JotDefaultsKey.fnRequested,
                                 JotDefaultsKey.dictationShortcut, JotDefaultsKey.selectedInputUID, JotDefaultsKey.personalVocabulary]

    /// TranscriptStore's database in Jot's directory, or a preference an earlier run saved. The shared FluidAudio model cache is not
    /// evidence: another app may have filled it.
    static func hasEarlierInstall(defaults: UserDefaults, directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcripts.sqlite3").path) { return true }
        return earlierUseKeys.contains { defaults.object(forKey: $0) != nil }
    }
}
