import AppKit
import Foundation
import JotCore

/// Checks GitHub Releases on demand or once a day, and swaps /Applications/Jot.app for a verified download signed by the same team.
/// A check only reads the release list; downloading waits for Update Jot.
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate(String), available(ReleaseInfo), downloading(Double), finishing, installing, failed(String)
    }
    @Published private(set) var state = State.idle
    // The list endpoint, not /releases/latest: development-signed builds publish as pre-releases, which that endpoint hides.
    static let latestURL = URL(string: "https://api.github.com/repos/StoneHub/jot/releases?per_page=20")!
    static let installPath = "/Applications/Jot.app"
    static let officialTeamIdentifier = "N6GPP46885"
    /// A downloaded app must satisfy this: a certificate chain to Apple whose leaf names Jot's team. codesign checks it
    /// against the signature itself rather than the TeamIdentifier text it prints. Casks/jot.rb uses the same requirement.
    static let officialRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(officialTeamIdentifier)\""
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Jot/update.log")
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .finishing, .installing: return true
        default: return false
        }
    }
    /// Set by the menu bar's update line; the window answers by showing Models & updates.
    @Published var revealRequested = false
    private var progressObservation: NSKeyValueObservation?
    private let settings: JotSettings
    private var dailyChecks: Task<Void, Never>?
    /// No cookies, cache or credentials: a check sends GitHub nothing about this Mac beyond the request itself.
    private let session = URLSession(configuration: .ephemeral)

    init(settings: JotSettings = .standard) {
        self.settings = settings
    }

    func check() {
        guard !isBusy else { return }
        state = .checking
        Task {
            do { state = try await latestState() } catch { state = .failed(error.localizedDescription) }
        }
    }

    /// Five minutes after launch, then every six hours, check if the switch is on and a day has passed since the last
    /// answer. The hour of tolerance lets macOS fold the wake into other work.
    func startDailyChecks() {
        dailyChecks?.cancel()
        dailyChecks = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5 * 60)) } catch { return }
            while !Task.isCancelled {
                await self?.checkIfDue()
                do { try await Task.sleep(for: .seconds(6 * 60 * 60), tolerance: .seconds(60 * 60)) } catch { return }
            }
        }
    }

    /// The daily check stays quiet: being offline, a source-built copy or a GitHub error leaves the card as it was,
    /// and a check or update the person started meanwhile keeps its own state.
    private func checkIfDue() async {
        guard settings.bool(JotDefaultsKey.checkForUpdates), !isBusy,
              UpdateCheckSchedule.isDue(lastCheck: UpdateCheckSchedule.lastCheck(in: settings.defaults), now: Date()) else { return }
        guard let latest = try? await latestState(), !isBusy else { return }
        state = latest
    }

    private func latestState() async throws -> State {
        var request = URLRequest(url: Self.latestURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Any answer counts toward the once-a-day limit, so an error GitHub keeps giving is not asked again every six hours.
        UpdateCheckSchedule.recordCheck(in: settings.defaults, at: Date())
        // GitHub answers 404 while the repository has no release at all.
        if http.statusCode == 404 { return .upToDate(JotVersion.current) }
        guard http.statusCode == 200 else { throw UpdateError("GitHub answered \(http.statusCode).") }
        let release = try ReleaseInfo.newest(from: data) { "Jot-\($0).zip" }
        guard let installed = SemanticVersion.parse(JotVersion.current) else { throw UpdateError("Installed version \(JotVersion.current) is not a version.") }
        guard release.version > installed else { return .upToDate(JotVersion.current) }
        let running = Bundle.main.bundleURL
        let runningTeam = try await Task.detached { try Self.teamIdentifier(of: running) }.value
        guard runningTeam == Self.officialTeamIdentifier else {
            throw UpdateError("This source-built copy is signed by team \(runningTeam). Install an official Jot download once to use automatic updates.")
        }
        return .available(release)
    }

    /// Download and verify while listening continues; only then finish captured work before replacing the app.
    func install(service: SpeechService) {
        guard case .available(let release) = state else { return }
        state = .downloading(0)
        Task {
            let staging = FileManager.default.temporaryDirectory.appending(path: "jot-update-\(UUID().uuidString)")
            do {
                // Before the download, so an account that can't replace the app isn't told so only after the whole zip.
                try Self.checkReplaceable()
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                log("update \(JotVersion.current) -> \(release.version); staging \(staging.path)")
                let zip = try await download(release, to: staging)
                log("downloaded \(zip.lastPathComponent), \(release.assetSize) bytes")
                state = .installing
                try await run("/usr/bin/ditto", "-x", "-k", zip.path, staging.path)
                let bundle = staging.appending(path: "Jot.app")
                try await verify(bundle, expecting: release.version)
                log("verified \(bundle.path)")
                state = .finishing
                try await service.prepareForUpdate()
                state = .installing
                try swap(bundle, staging: staging)
            } catch {
                service.cancelUpdatePreparation()
                log("failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: staging)
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ release: ReleaseInfo, to directory: URL) async throws -> URL {
        let destination = directory.appending(path: release.downloadURL.lastPathComponent)
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: release.downloadURL) { url, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url, let response else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                // Move inside the handler; the system deletes the temporary file once it returns.
                do { try FileManager.default.moveItem(at: url, to: destination); continuation.resume(returning: response) }
                catch { continuation.resume(throwing: error) }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
            }
            task.resume()
        }
        progressObservation = nil
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError("Download failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
        guard size == release.assetSize else { throw UpdateError("Download is \(size) bytes; the release lists \(release.assetSize).") }
        return destination
    }

    private func verify(_ bundle: URL, expecting version: SemanticVersion) async throws {
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw UpdateError("The download did not contain Jot.app.") }
        do {
            try await run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=\(Self.officialRequirement)", bundle.path)
        } catch {
            throw UpdateError("The download is not signed by Jot's team (\(Self.officialTeamIdentifier)). \(error.localizedDescription)")
        }
        // Unnotarized Apple Development signatures fail Gatekeeper while the quarantine flag is set; xattr exits nonzero when there is none.
        try await run("/usr/bin/xattr", "-dr", "com.apple.quarantine", bundle.path, allowFailure: true)
        let info = bundle.appending(path: "Contents/Info.plist")
        let bundleVersion = (NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.parse)
        guard bundleVersion == version else { throw UpdateError("Downloaded app reports version \(bundleVersion?.description ?? "unknown"), expected \(version).") }
    }

    /// The swap moves the installed app aside after Jot quits; check that it can while Jot is still running,
    /// so an update that cannot finish fails here instead of leaving Jot closed.
    private static func checkReplaceable() throws {
        let folder = (installPath as NSString).deletingLastPathComponent
        guard access(folder, W_OK) == 0, access(installPath, F_OK) != 0 || access(installPath, W_OK) == 0 else {
            throw UpdateError("Jot can't replace \(installPath) without an administrator. Download the update from the release page instead.")
        }
    }

    /// The running app cannot replace itself, so a detached shell script does the swap after this process exits.
    private func swap(_ bundle: URL, staging: URL) throws {
        let script = staging.appending(path: "swap.sh")
        let text = """
        #!/bin/sh
        pid="$1"; new="$2"; previous="$3"; log="$4"; target="\(Self.installPath)"
        note() { echo "$(date '+%Y-%m-%dT%H:%M:%S') swap: $1" >> "$log"; }
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        note "app pid $pid exited"
        if [ -e "$target" ]; then
            mv "$target" "$previous" || { note "could not move the current app aside; relaunching it"; open "$target"; exit 1; }
            note "moved current app to $previous"
        fi
        if mv "$new" "$target"; then
            if codesign --verify --deep --strict "$target" 2>>"$log"; then
                note "installed new app at $target"
            else
                note "new app failed the signature check; restoring the previous app"
                mv "$target" "$previous.rejected" && [ -e "$previous" ] && mv "$previous" "$target"
            fi
        else
            note "could not move the new app into place; restoring the previous app"
            [ -e "$previous" ] && mv "$previous" "$target"
        fi
        open "$target" && note "launched $target"
        # One Jot on disk: the copy kept for rollback goes once the new app has launched.
        [ -e "$previous" ] && rm -rf "$previous" && note "removed the previous app"
        # The staging folder holds the zip, this script and any rejected app; keep it only if no app is in place.
        [ -e "$target" ] && rm -rf "$(dirname "$new")" && note "removed the staging folder"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let previous = staging.appending(path: "Jot-previous.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), bundle.path, previous.path, Self.logURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        log("swap script started (pid \(process.processIdentifier)); quitting so it can replace \(Self.installPath)")
        NSApp.terminate(nil)
    }

    /// Blocking; callers run it off the main actor.
    nonisolated private static func teamIdentifier(of bundle: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", bundle.path]
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("codesign could not read \(bundle.lastPathComponent).") }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        throw UpdateError("\(bundle.lastPathComponent) has no TeamIdentifier.")
    }

    /// Unzipping and deep signature checks take seconds; they run off the main actor so listening and the window keep going.
    private func run(_ executable: String, _ arguments: String..., allowFailure: Bool = false) async throws {
        let (status, stderr) = try await Task.detached { () throws -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
            try process.run()
            let stderr = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            return (process.terminationStatus, stderr)
        }.value
        let name = URL(fileURLWithPath: executable).lastPathComponent
        log("\(name) \(arguments.joined(separator: " ")) -> exit \(status)")
        guard status == 0 || allowFailure else {
            throw UpdateError("\(name) failed: \(stderr.isEmpty ? "exit \(status)" : stderr)")
        }
    }

    // Local time, the same format the swap script writes with date(1), so the two halves of one update read in order.
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
    private func log(_ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(message)\n"
        let url = Self.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
