import AppKit
import Foundation
import JotCore

/// Checks GitHub Releases on demand and swaps /Applications/Jot.app for a verified download signed by the same team.
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate(String), available(ReleaseInfo), downloading(Double), installing, failed(String)
    }
    @Published private(set) var state = State.idle
    static let latestURL = URL(string: "https://api.github.com/repos/StoneHub/jot/releases/latest")!
    static let installPath = "/Applications/Jot.app"
    static let officialTeamIdentifier = "N6GPP46885"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Jot/update.log")
    private var progressObservation: NSKeyValueObservation?

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: Self.latestURL)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                // GitHub answers 404 while the repository has no release at all.
                if http.statusCode == 404 { state = .upToDate(JotVersion.current); return }
                guard http.statusCode == 200 else { throw UpdateError("GitHub answered \(http.statusCode).") }
                let release = try ReleaseInfo.latest(from: data) { "Jot-\($0).zip" }
                guard let installed = SemanticVersion.parse(JotVersion.current) else { throw UpdateError("Installed version \(JotVersion.current) is not a version.") }
                if release.version > installed {
                    let runningTeam = try Self.teamIdentifier(of: Bundle.main.bundleURL)
                    guard runningTeam == Self.officialTeamIdentifier else {
                        throw UpdateError("This source-built copy is signed by team \(runningTeam). Install an official Jot download once to use automatic updates.")
                    }
                    state = .available(release)
                } else {
                    state = .upToDate(JotVersion.current)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// The caller checks SpeechService.canInstallUpdate first; this only requires that a release was found.
    func install() {
        guard case .available(let release) = state else { return }
        state = .downloading(0)
        Task {
            let staging = FileManager.default.temporaryDirectory.appending(path: "jot-update-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                log("update \(JotVersion.current) -> \(release.version); staging \(staging.path)")
                let zip = try await download(release, to: staging)
                log("downloaded \(zip.lastPathComponent), \(release.assetSize) bytes")
                state = .installing
                try run("/usr/bin/ditto", "-x", "-k", zip.path, staging.path)
                let bundle = staging.appending(path: "Jot.app")
                try verify(bundle, expecting: release.version)
                log("verified \(bundle.path)")
                try swap(bundle, staging: staging)
            } catch {
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

    private func verify(_ bundle: URL, expecting version: SemanticVersion) throws {
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw UpdateError("The download did not contain Jot.app.") }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", bundle.path)
        let running = try Self.teamIdentifier(of: Bundle.main.bundleURL)
        let downloaded = try Self.teamIdentifier(of: bundle)
        guard running == downloaded else { throw UpdateError("Signing team \(downloaded) does not match the installed app (\(running)).") }
        // Unnotarized Apple Development signatures fail Gatekeeper while the quarantine flag is set; xattr exits nonzero when there is none.
        try run("/usr/bin/xattr", "-dr", "com.apple.quarantine", bundle.path, allowFailure: true)
        let info = bundle.appending(path: "Contents/Info.plist")
        let bundleVersion = (NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.parse)
        guard bundleVersion == version else { throw UpdateError("Downloaded app reports version \(bundleVersion?.description ?? "unknown"), expected \(version).") }
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
            mv "$target" "$previous" || { note "could not move the current app aside"; exit 1; }
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

    private static func teamIdentifier(of bundle: URL) throws -> String {
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

    private func run(_ executable: String, _ arguments: String..., allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
        try process.run()
        let stderr = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        let name = URL(fileURLWithPath: executable).lastPathComponent
        log("\(name) \(arguments.joined(separator: " ")) -> exit \(process.terminationStatus)")
        guard process.terminationStatus == 0 || allowFailure else {
            throw UpdateError("\(name) failed: \(stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)")
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
