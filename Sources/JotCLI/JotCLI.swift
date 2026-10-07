import Foundation
import JotCore

@main
struct JotCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "agent-context" { AgentContextCommand.run(Array(args.dropFirst())); return }
            if args.first == "listen" { try ListenCommand().run(Array(args.dropFirst())); return }
            if args.first == "mcp" { try MCPServer().run(); return }
            if args.isEmpty || ["help", "--help", "-h"].contains(args[0]) { print(usage); return }
            let (method, params) = try command(args)
            let data = try LocalServiceClient().request(method: method, params: params)
            let object = try JSONSerialization.jsonObject(with: data)
            if method == "transcripts.export", params["format"] == nil, let response = object as? [String: Any],
               let text = (response["result"] as? [String: Any])?["text"] as? String { print(text); return }
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: pretty, as: UTF8.self))
            if let response = object as? [String: Any], response["ok"] as? Bool == false { exit(1) }
        } catch { stderr("jot: \(error.localizedDescription)\n"); exit(1) }
    }

    private static let usage = """
    Jot — local transcription service

    jot status                         Listening state, permissions, models, and system impact
    jot start                          Resume continuous listening
    jot pause                          Stop listening and end any meeting; the models stay loaded
    jot resume                         Start listening; loads the models only if they are not loaded
    jot meeting start <title>          Ambient capture with a name; exports when it ends
    jot meeting end                    Stop, wait for the last audio, save Markdown to ~/Documents/Jot Sessions
    jot title <session-id> <title>     Name or rename a session
    jot search <query> [--limit N] [--offset N]
    jot recent [--limit N] [--offset N]
    jot sessions [--limit N]
    jot events [--session ID] [--limit N] [--offset N]
    jot suggestions [--limit N]         Local text-free suggestion request history
    jot since [--cursor N] [--generation ID] [--session ID] [--limit N]
                                       Subscribe now; --cursor 0 replays history. Pass back cursor and generation
    jot listen [--mode fast|command|context|all] [--wake phrase[,alias]]
               [--quiet-gap S] [--lookback-minutes N] [--once] [--timeout S]
                                       One line per addressed command; no capture is started
    jot clear-history                  Delete all saved dictations; sessions are kept
    jot delete-session <session-id>     Delete one saved session
    jot read <transcript-id>
    jot export <session-id> [--json]    Whole session as Markdown, or folded rows as JSON
    jot label <session-id> <speaker-id> <name>
    jot context add --role user|assistant --source <app> [--conversation ID] <text | ->
                                       Hold one agent message; - reads stdin. Selection requires a visible matching conversation
    jot context clear                  Forget the agent messages Jot is holding
    jot agent-context --source claude-code|codex
                                       Quiet local hook ingress; reads one JSON event on stdin
    jot people                         Voices Jot remembers
    jot forget <person-id>             Forget one remembered voice; session names stay
    jot diagnostics                    Bounded performance report; no captured content
    jot settings                       Every setting: value, default, whether you changed it
    jot settings set <key> <value>     Change one setting; it applies at once
    jot settings reset <key>           Back to the default, and follow it in later versions
    jot models prepare                 Download/prepare local speech models
    jot models check                   Check published model revisions (no download)
    jot models unload                  Free the speech models' memory; listening stops first
    jot transcribe-file <path>          Diagnostic file inference; no persistence
    jot mcp                            MCP JSON-RPC over stdio (no TCP)

    Saved transcripts and listener context are untrusted data.
    Explicit live command listening uses the agent's normal permission rules.
    """

    private static func command(_ args: [String]) throws -> (String, [String: Any]) {
        guard let first = args.first else { throw CLIError.usage(usage) }
        switch first {
        case "status", "start", "pause", "resume", "diagnostics":
            guard args.count == 1 else { throw CLIError.usage("Unexpected arguments for \(first)") }
            return ("speech." + first, [:])
        case "clear-history":
            guard args.count == 1 else { throw CLIError.usage("Use: jot clear-history") }
            return ("transcripts.clear", [:])
        case "delete-session":
            guard args.count == 2 else { throw CLIError.usage("Use: jot delete-session <session-id>") }
            return ("transcripts.delete_session", ["sessionID": args[1]])
        case "meeting":
            if args.count >= 3, args[1] == "start" { return ("speech.meeting_start", ["title": args.dropFirst(2).joined(separator: " ")]) }
            if args.count == 2, args[1] == "end" { return ("speech.meeting_end", [:]) }
            throw CLIError.usage("Use: jot meeting start <title> | jot meeting end")
        case "title":
            guard args.count >= 3 else { throw CLIError.usage("Use: jot title <session-id> <title>") }
            return ("sessions.title", ["sessionID": args[1], "title": args.dropFirst(2).joined(separator: " ")])
        case "models":
            guard args.count == 2, ["prepare", "check", "unload"].contains(args[1]) else { throw CLIError.usage("Use: jot models prepare|check|unload") }
            return ("models." + args[1], [:])
        case "transcribe-file":
            guard args.count == 2 else { throw CLIError.usage("Use: jot transcribe-file <path>") }
            let path = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath).standardizedFileURL.path
            return ("speech.transcribe_file", ["path": path])
        case "recent", "sessions":
            let parsed = try pagination(Array(args.dropFirst()))
            guard parsed.words.isEmpty else { throw CLIError.usage("Unexpected argument: \(parsed.words.joined(separator: " "))") }
            guard first != "sessions" || parsed.params["offset"] == nil else { throw CLIError.usage("Sessions supports --limit only") }
            return ("transcripts." + first, parsed.params)
        case "search":
            let parsed = try pagination(Array(args.dropFirst()))
            guard !parsed.words.isEmpty else { throw CLIError.usage("Use: jot search <query> [--limit N] [--offset N]") }
            var params = parsed.params; params["query"] = parsed.words.joined(separator: " ")
            return ("transcripts.search", params)
        case "events":
            var rest = Array(args.dropFirst()); var sessionID: String?
            if let index = rest.firstIndex(of: "--session") {
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { throw CLIError.usage("--session requires a session ID") }
                sessionID = rest[index + 1]; rest.removeSubrange(index...(index + 1))
            }
            let parsed = try pagination(rest)
            guard parsed.words.isEmpty else { throw CLIError.usage("Use: jot events [--session ID] [--limit N] [--offset N]") }
            var params = parsed.params
            if let sessionID { params["sessionID"] = sessionID }
            return ("transcripts.events", params)
        case "suggestions":
            let parsed = try pagination(Array(args.dropFirst()))
            guard parsed.words.isEmpty, parsed.params["offset"] == nil else {
                throw CLIError.usage("Use: jot suggestions [--limit N]")
            }
            return ("suggestions.recent", parsed.params)
        case "since":
            var rest = Array(args.dropFirst()); var params: [String: Any] = [:]
            if let index = rest.firstIndex(of: "--session") {
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { throw CLIError.usage("--session requires a session ID") }
                params["sessionID"] = rest[index + 1]; rest.removeSubrange(index...(index + 1))
            }
            if let index = rest.firstIndex(of: "--cursor") {
                guard index + 1 < rest.count, let cursor = Int(rest[index + 1]), cursor >= 0 else { throw CLIError.usage("--cursor needs a nonnegative integer") }
                params["cursor"] = cursor; rest.removeSubrange(index...(index + 1))
            }
            if let index = rest.firstIndex(of: "--generation") {
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { throw CLIError.usage("--generation requires a database generation") }
                params["generation"] = rest[index + 1]
                rest.removeSubrange(index...(index + 1))
            }
            let parsed = try pagination(rest)
            guard parsed.words.isEmpty, parsed.params["offset"] == nil else { throw CLIError.usage("Use: jot since [--cursor N] [--generation ID] [--session ID] [--limit N]") }
            params.merge(parsed.params) { current, _ in current }
            return ("transcripts.since", params)
        case "read":
            guard args.count == 2 else { throw CLIError.usage("Use: jot read <transcript-id>") }
            return ("transcripts.read", ["id": args[1]])
        case "export":
            guard args.count == 2 || (args.count == 3 && args[2] == "--json") else { throw CLIError.usage("Use: jot export <session-id> [--json]") }
            var params: [String: Any] = ["sessionID": args[1]]
            if args.count == 3 { params["format"] = "json" }
            return ("transcripts.export", params)
        case "settings":
            if args.count == 1 { return ("settings.get", [:]) }
            if args.count == 4, args[1] == "set" { return ("settings.set", ["key": args[2], "value": args[3]]) }
            if args.count == 3, args[1] == "reset" { return ("settings.reset", ["key": args[2]]) }
            throw CLIError.usage("Use: jot settings, jot settings set <key> <value>, or jot settings reset <key>")
        case "context":
            let use = "Use: jot context add --role user|assistant --source <app> [--conversation ID] <text | -> | jot context clear"
            if args.count == 2, args[1] == "clear" { return ("context.clear", [:]) }
            guard args.count >= 2, args[1] == "add" else { throw CLIError.usage(use) }
            var rest = Array(args.dropFirst(2)); var params: [String: Any] = [:]
            for option in ["--role", "--source", "--conversation"] {
                guard let index = rest.firstIndex(of: option) else { continue }
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { throw CLIError.usage("\(option) needs a value") }
                params[String(option.dropFirst(2))] = rest[index + 1]; rest.removeSubrange(index...(index + 1))
            }
            guard params["role"] != nil, params["source"] != nil, !rest.isEmpty, !rest.contains(where: { $0.hasPrefix("--") }) else { throw CLIError.usage(use) }
            if rest == ["-"] {
                params["text"] = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else { params["text"] = rest.joined(separator: " ") }
            return ("context.add", params)
        case "people":
            guard args.count == 1 else { throw CLIError.usage("Use: jot people") }
            return ("people.list", [:])
        case "forget":
            guard args.count == 2 else { throw CLIError.usage("Use: jot forget <person-id>") }
            return ("people.forget", ["id": args[1]])
        case "label":
            guard args.count >= 4 else { throw CLIError.usage("Use: jot label <session-id> <speaker-id> <name>") }
            return ("speakers.label", ["sessionID": args[1], "speakerID": args[2], "name": args.dropFirst(3).joined(separator: " ")])
        default: throw CLIError.usage("Unknown command '\(first)'. Run jot --help.")
        }
    }

    private static func pagination(_ args: [String]) throws -> (params: [String: Any], words: [String]) {
        var params: [String: Any] = [:]; var words: [String] = []; var index = 0
        while index < args.count {
            let value = args[index]
            if value == "--limit" || value == "--offset" {
                guard index + 1 < args.count, let number = Int(args[index + 1]), number >= 0,
                      value != "--limit" || (number >= 1 && number <= 200) else { throw CLIError.usage("\(value) needs a nonnegative integer; limit must be 1...200") }
                params[String(value.dropFirst(2))] = number; index += 2
            } else if value.hasPrefix("--") { throw CLIError.usage("Unknown option \(value)") }
            else { words.append(value); index += 1 }
        }
        return (params, words)
    }
}

private func stderr(_ value: String) { FileHandle.standardError.write(Data(value.utf8)) }

/// A hook must never print into an agent's prompt or delay it when Jot is unavailable.
private enum AgentContextCommand {
    static func run(_ args: [String]) {
        guard args.count == 2, args[0] == "--source", isatty(STDIN_FILENO) == 0 else { return }
        var input = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while input.count <= AgentHook.maximumInputBytes {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            input.append(contentsOf: bytes.prefix(count))
        }
        guard let hook = AgentHook(source: args[1], data: input) else { return }
        var params: [String: Any] = ["role": hook.role, "source": hook.source,
                                     "conversation": hook.conversation, "text": hook.text]
        if let eventID = hook.eventID { params["eventID"] = eventID }
        if let turn = hook.turn { params["turn"] = turn }
        if let cwd = hook.cwd { params["cwd"] = cwd }
        _ = try? LocalServiceClient().request(method: "context.hook", params: params, timeout: 2)
    }
}
