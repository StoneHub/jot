import AppKit
import Foundation
import JotCore

/// Puts a downloaded Release build where the updater expects it. Runs before the window and the service, so nothing is
/// recording yet; every path ends in this copy continuing, or in the installed copy opening and this one exiting.
@MainActor
enum InstallLocation {
    static func settle() {
        let installPath = AppUpdater.installPath
        let installedURL = URL(fileURLWithPath: installPath)
        let exists = FileManager.default.fileExists(atPath: installPath)
        let installedVersion = exists ? version(of: installedURL) : nil
        let installedRunning = exists && NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.bundleURL?.standardizedFileURL.path == installPath }
        let placement = InstallPlacement.decide(runningPath: Bundle.main.bundlePath, installPath: installPath,
            running: SemanticVersion.parse(JotVersion.current), installed: installedVersion, installedExists: exists,
            installedIsRunning: installedRunning, declinedInstall: UserDefaults.standard.bool(forKey: JotDefaultsKey.declinedApplicationsInstall))
        switch placement {
        case .stay: return
        case .openInstalled:
            let alert = NSAlert()
            alert.messageText = "Jot is already in Applications"
            alert.informativeText = "This copy is the same version or older. It will close and open the installed Jot."
            alert.addButton(withTitle: "Open Jot")
            alert.runModal()
            openInstalled()
        case .installedRunning:
            let alert = NSAlert()
            alert.messageText = "Quit Jot to install this newer copy"
            alert.informativeText = "The Jot in Applications is running. Quit it from its menu bar icon, then open this copy again to replace it."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            exit(0)
        case .offerInstall:
            let alert = NSAlert()
            alert.messageText = "Move Jot to Applications?"
            alert.informativeText = "Jot works best from the Applications folder, where it can update itself and keep its permissions."
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Not Now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: JotDefaultsKey.declinedApplicationsInstall) }
            guard response == .alertFirstButtonReturn else { return }
            install(replacing: false)
        case .offerReplace(let installed):
            let alert = NSAlert()
            alert.messageText = "Replace Jot \(installed) with \(JotVersion.current)?"
            alert.informativeText = "This copy is newer than the Jot in Applications. Replacing it keeps your transcripts, settings and models; the older app goes to the Trash."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Open Installed Jot")
            if alert.runModal() == .alertFirstButtonReturn { install(replacing: true) } else { openInstalled() }
        }
    }

    /// Copies this bundle into Applications, then opens it and exits. A translocated copy is read-only, so it is copied,
    /// not moved. On failure the older app comes back from the Trash and this copy keeps running.
    private static func install(replacing: Bool) {
        let target = URL(fileURLWithPath: AppUpdater.installPath)
        var trashed: NSURL?
        do {
            if replacing { try FileManager.default.trashItem(at: target, resultingItemURL: &trashed) }
            try run("/usr/bin/ditto", Bundle.main.bundlePath, target.path)
            // The user already chose to open this copy; the installed one should not ask again.
            try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", target.path)
            openInstalled()
        } catch {
            if !FileManager.default.fileExists(atPath: target.path), let trashed = trashed as URL? {
                try? FileManager.default.moveItem(at: trashed, to: target)
            }
            let alert = NSAlert()
            alert.messageText = "Jot could not be copied to Applications"
            alert.informativeText = "\(error.localizedDescription) Jot keeps running from here; drag it to Applications in Finder to install it."
            alert.runModal()
        }
    }

    private static func openInstalled() -> Never {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppUpdater.installPath))
        exit(0)
    }

    private static func version(of bundle: URL) -> SemanticVersion? {
        (NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.parse)
    }

    private static func run(_ executable: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Jot", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) failed."])
        }
    }
}
