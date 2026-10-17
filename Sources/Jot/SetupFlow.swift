import AVFoundation
import Combine
import Foundation
import JotCore

/// Where first-run setup stands, and the request to show it. Models, permissions and settings stay in SpeechService; this keeps only the progress, in SetupProgress.
@MainActor
final class SetupFlow: ObservableObject {
    @Published private(set) var progress = SetupProgress()
    /// The page on screen. Moving saves it, so setup resumes there after a relaunch.
    @Published private(set) var step = SetupStep.welcome
    /// Launch and the Set Up Jot command set this; the window switches to Setup and clears it, including when the window opens later.
    @Published var requested = false

    /// Before the service opens the store. An unfinished setup comes to the front, at the page it left, or earlier when a requirement is unmet now.
    func launch(readiness: SetupReadiness) {
        progress = SetupProgress.atLaunch(defaults: .standard, directory: JotPaths.directory)
        step = progress.resumeStep(readiness)
        requested = progress.offeredAtLaunch
    }

    /// The Set Up Jot command: where setup left off, or the summary once it is done.
    func open(readiness: SetupReadiness) {
        step = progress.resumeStep(readiness)
        requested = true
    }

    func go(to next: SetupStep) {
        step = next
        progress.step = next
        progress.save(to: .standard)
    }

    /// Launch stops opening setup; the Setup page and the menu command still do.
    func finishLater() {
        progress.status = .deferred
        progress.save(to: .standard)
    }

    func complete() {
        progress.status = .completed
        go(to: .summary)
    }
}

extension SpeechService {
    /// What setup's requirements read: models loaded now or by an earlier Resume, and both permissions.
    var setupReadiness: SetupReadiness {
        SetupReadiness(modelsReady: modelsLoaded || UserDefaults.standard.bool(forKey: JotDefaultsKey.modelsPrepared),
                       microphoneAllowed: micPermission == .authorized, accessibilityAllowed: accessibilityGranted)
    }
}
