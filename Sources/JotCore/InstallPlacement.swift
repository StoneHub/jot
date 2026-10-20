import Foundation

/// What a Release build does at launch about where it runs from. The updater replaces /Applications/Jot.app, so a copy
/// anywhere else (Downloads, a translocated quarantine mount, a disk image) offers to put itself there.
public enum InstallPlacement: Equatable, Sendable {
    /// Already the installed copy, or the user asked not to be asked again.
    case stay
    /// The installed copy is the same version or newer: open it and close this one.
    case openInstalled
    /// Nothing is installed yet: offer to copy this one to Applications.
    case offerInstall
    /// This copy is newer than the installed one: offer to replace it.
    case offerReplace(installed: SemanticVersion)
    /// This copy is newer, but the installed one is running and cannot be replaced under it.
    case installedRunning

    public static func decide(runningPath: String, installPath: String, running: SemanticVersion?,
                              installed: SemanticVersion?, installedExists: Bool, installedIsRunning: Bool,
                              declinedInstall: Bool) -> InstallPlacement {
        guard runningPath != installPath else { return .stay }
        guard installedExists else { return declinedInstall ? .stay : .offerInstall }
        // An unreadable version on either side keeps the old rule: the installed copy wins.
        guard let running, let installed, running > installed else { return .openInstalled }
        return installedIsRunning ? .installedRunning : .offerReplace(installed: installed)
    }
}
