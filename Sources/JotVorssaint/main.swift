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

func call(_ method: String, _ params: [String: Any] = [:], timeout: Int = 30) throws -> Any {
    let data = try client.request(method: method, params: params, timeout: timeout)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = object["ok"] as? Bool
    else { throw HelperError("Jot returned an invalid response.") }
    guard ok else { throw HelperError(object["error"] as? String ?? "Jot could not do that.") }
    return object["result"] ?? [:]
}

func controls() throws -> ControlSnapshot {
    try JSONDecoder().decode(ControlSnapshot.self, from: JSONSerialization.data(withJSONObject: call("speech.controls", timeout: 2)))
}

while let line = readLine() {
    guard line.utf8.count <= 4096 else { exit(2) }
    revision += 1
    var reply: [String: Any] = ["version": 1, "instance": "jot-not-running", "status": "Open Jot to connect",
                                "phase": "idle", "level": 0, "enabledActions": ["open"]]
    do {
        guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              request["version"] as? Int == 1, let action = request["action"] as? String,
              action == "observe" || VorssaintPresentation.actions.contains(action)
        else { throw HelperError("Vorssaint sent a request this Jot does not support.") }
        if action == "open" { NSWorkspace.shared.open(app) }
        if let jot = NSRunningApplication.runningApplications(withBundleIdentifier: "space.jot.app").first(where: { !$0.isTerminated }) {
            switch action {
            case "quit": jot.terminate()
            case "listen": _ = try call("speech.resume")
            case "pause": _ = try call("speech.pause")
            case "meeting.start":
                let title = (request["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 200 else { throw HelperError("Give the meeting a title.") }
                _ = try call("speech.meeting_start", ["title": title])
            case "meeting.end": _ = try call("speech.meeting_end")
            default: break
            }
            var state = try controls()
            let deadline = Date().addingTimeInterval(3)
            while !VorssaintPresentation.settled(after: action, state) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                state = try controls()
            }
            reply.merge(presentation.reply(state, process: jot.processIdentifier)) { $1 }
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
