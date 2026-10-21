import AppKit
import JotCore

// Vorssaint starts this helper from Jot.app while its Jot feature is on and
// sends one JSON request per line on stdin. Connecting never opens Jot or
// starts capture; only Open, Listen and Start Meeting do, at the person's click.

let client = LocalServiceClient()
let helpers = Bundle.main.bundleURL
let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
var presentation = VorssaintPresentation()
var revision: UInt64 = 0

struct HelperError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Actions keep the client's per-method timeouts: Start Meeting may wait for the models and End Meeting for the backlog.
func call(_ method: LocalMethod, _ params: [String: Any] = [:], timeout: Int? = nil) throws -> Any {
    let data = try client.request(method, params: params, timeout: timeout)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = object["ok"] as? Bool
    else { throw HelperError("Jot returned an invalid response.") }
    guard ok else { throw HelperError(object["error"] as? String ?? "Jot could not do that.") }
    return object["result"] ?? [:]
}

/// Asked only for a version 2 host. Jot answers it only for this helper and only while its setting is on; the text
/// goes straight into the reply and is never kept or logged here.
func preview() -> String? {
    (try? call(.speechPreview, timeout: 2) as? [String: Any])?["preview"] as? String
}

/// Always the latest snapshot; `VorssaintPresentation` leaves out what the host's version does not know.
func controls() throws -> ControlSnapshot {
    try ControlSnapshot.decode(JSONSerialization.data(withJSONObject:
        call(.speechControls, ["version": ControlSnapshot.latestVersion], timeout: 2)))
}

while let line = readLine() {
    guard line.utf8.count <= 4096 else { exit(2) }
    revision += 1
    let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    // Answer in the version the host asked for; a request this helper cannot read gets a version 1 error.
    let version = (request?["version"] as? Int).flatMap { VorssaintPresentation.versions.contains($0) ? $0 : nil }
    var reply: [String: Any] = ["version": version ?? 1, "instance": "jot-not-running", "status": "Open Jot to connect",
                                "phase": "idle", "level": 0, "enabledActions": ["open"]]
    do {
        guard let request, let version, let action = request["action"] as? String,
              action == "observe" || VorssaintPresentation.actions.contains(action)
        else { throw HelperError("Vorssaint sent a request this Jot does not support.") }
        if action == "open" { NSWorkspace.shared.open(app) }
        if let jot = NSRunningApplication.runningApplications(withBundleIdentifier: "space.jot.app").first(where: { !$0.isTerminated }) {
            switch action {
            case "quit": jot.terminate()
            case "listen":
                // A fresh install has no models; Jot asks before downloading them, so show it where that question is.
                let resumed = try call(.speechResume, ["askBeforeDownload": true]) as? [String: Any]
                if resumed?["downloadPrompt"] as? Bool == true { NSWorkspace.shared.open(app) }
            case "pause": _ = try call(.speechPause)
            case "meeting.start":
                let title = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 200 else { throw HelperError("Give the meeting a title.") }
                _ = try call(.speechMeetingStart, ["title": title])
            case "meeting.end": _ = try call(.speechMeetingEnd)
            default: break
            }
            var state = try controls()
            let deadline = Date().addingTimeInterval(3)
            while !VorssaintPresentation.settled(after: action, state) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                state = try controls()
            }
            reply.merge(presentation.reply(state, process: jot.processIdentifier, version: version,
                                           preview: version >= 2 ? preview() : nil)) { $1 }
        } else if action != "observe" && action != "open" {
            throw HelperError("Open Jot to connect.")
        }
    } catch {
        reply["error"] = String(error.localizedDescription.prefix(300))
    }
    reply["revision"] = revision
    if let data = try? JSONSerialization.data(withJSONObject: reply), let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    }
}
