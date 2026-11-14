import Foundation
import JotCore

/// `jot-lab <audio> --variants <file> --out <dir> [--captions <file>]`, or `jot-lab --set <folder> --out <dir> [--variants <file>]`,
/// launched by `jot lab`.
@MainActor
func labMain() async -> Int32 {
    let usage = "Use: jot lab <audio> --variants <file.json> --out <dir> [--captions <file.srt|.vtt>]\n"
        + "     jot lab --set <folder> --out <dir> [--variants <file.json>]"
    var arguments = Array(CommandLine.arguments.dropFirst())
    var options: [String: String] = [:]
    var positional: [String] = []
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        if ["--variants", "--out", "--captions", "--set"].contains(argument) {
            guard !arguments.isEmpty else { return fail(usage) }
            options[argument] = arguments.removeFirst()
        } else if argument.hasPrefix("--") {
            return fail("Unknown option \(argument). \(usage)")
        } else {
            positional.append(argument)
        }
    }
    guard let outPath = options["--out"] else { return fail(usage) }
    let output = url(outPath)
    do {
        // Private working files go to the user's temporary folder and are removed even when the run fails.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jot-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let interrupts = removeOnInterrupt(scratch)
        defer { interrupts.forEach { $0.cancel() } }
        if let setPath = options["--set"] {
            guard positional.isEmpty, options["--captions"] == nil else { return fail(usage) }
            try await runSet(folder: url(setPath), variantsPath: options["--variants"].map(url), output: output, scratch: scratch)
            return 0
        }
        guard positional.count == 1, let variantsPath = options["--variants"] else { return fail(usage) }
        let audio = url(positional[0])
        guard FileManager.default.isReadableFile(atPath: audio.path) else { throw LabError.invalid("Cannot read \(audio.path).") }
        let variants = try LabVariant.parse(Data(contentsOf: url(variantsPath)))
        let captions = try options["--captions"].map { try LabCaptions.parse(String(contentsOf: url($0), encoding: .utf8)) }
        try prepareOutput(output)
        _ = try await runRecording(audio, variants: variants, captions: captions, output: output, scratch: scratch)
        print("Wrote \(output.appendingPathComponent("report.html").path) and variants.json.")
        return 0
    } catch {
        return fail(error.localizedDescription)
    }
}

/// One recording through the lab: `variants.json` and `report.html` in `output`, one summary line per variant.
@MainActor
func runRecording(_ audio: URL, variants: [LabVariant], captions: [LabCaptions.Cue]?, output: URL, scratch: URL) async throws -> [LabVariantResult] {
    let lab = TuningLab(audio: audio, variants: variants, captions: captions, scratch: scratch,
        base: UserDefaults(suiteName: "space.jot.app"), log: { print($0); fflush(stdout) })
    let results = try await lab.run()
    try LabReport.json(results).write(to: output.appendingPathComponent("variants.json"))
    try LabReport.html(audioName: audio.lastPathComponent, variants: results).write(to: output.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
    for result in results {
        let score = result.score.map { String(format: ", WER %.1f%% raw, %.1f%% cleaned", $0.raw.rate * 100, $0.cleaned.rate * 100) } ?? ""
        let speakers = [("live", result.score?.liveSpeakers), ("pass", result.score?.passSpeakers)].compactMap { name, speakers in
            speakers.map { ", \(name) speakers " + String(format: "%.1f%% of words right", $0.accuracy * 100) }
        }.joined()
        print("\(result.name): \(result.rows.count) rows, \(result.paragraphs.count) paragraphs, \(Set(result.rows.compactMap(\.passSpeaker)).count) pass speakers\(score)\(speakers)")
    }
    return results
}

/// Every item of a set, each into its own folder under `output`, then `set-scores.json` and `set-report.md` with the
/// numbers only, so those two can leave the Mac while the transcripts stay in the item folders.
@MainActor
func runSet(folder: URL, variantsPath: URL?, output: URL, scratch: URL) async throws {
    let set = try LabSet.load(folder)
    let variants = try variantsPath.map { try LabVariant.parse(Data(contentsOf: $0)) } ?? [LabVariant(name: "current", settings: [:])]
    try prepareOutput(output)
    var items: [LabSetScores.Item] = []
    for (index, item) in set.items.enumerated() {
        print("Item \(index + 1) of \(set.items.count): \(item.name)")
        let captions = try LabCaptions.parse(String(contentsOf: set.captions(item, in: folder), encoding: .utf8))
        let itemOutput = output.appendingPathComponent(item.name, isDirectory: true)
        try FileManager.default.createDirectory(at: itemOutput, withIntermediateDirectories: true)
        let results = try await runRecording(set.audio(item, in: folder), variants: variants, captions: captions, output: itemOutput, scratch: scratch)
        let scored = try LabSetScores.Item(name: item.name, results: results)
        items.append(scored)
    }
    let scores = LabSetScores(set: set.name, items: items)
    try scores.json().write(to: output.appendingPathComponent("set-scores.json"))
    let report = "# Jot lab set \(set.name)\n\nJot \(scores.jotVersion), \(items.count) items.\n\n" + scores.table() + "\n"
    try report.write(to: output.appendingPathComponent("set-report.md"), atomically: true, encoding: .utf8)
    print(scores.table())
    print("Wrote \(output.appendingPathComponent("set-scores.json").path) and set-report.md; each item's transcript is in its folder.")
}

/// Recordings and their transcripts are private: the output goes to an empty folder outside any git repository.
func prepareOutput(_ output: URL) throws {
    var directory = output.standardizedFileURL
    while directory.path != "/" {
        directory = directory.resolvingSymlinksInPath().standardizedFileURL
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            throw LabError.invalid("\(output.path) is inside the git repository at \(directory.path); choose a folder outside it.")
        }
        directory.deleteLastPathComponent()
    }
    if let existing = try? FileManager.default.contentsOfDirectory(atPath: output.path), !existing.filter({ $0 != ".DS_Store" }).isEmpty {
        throw LabError.invalid("\(output.path) is not empty; choose a new folder.")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
}

/// Interrupt, termination, hangup and broken-pipe signals remove the private working files before exit.
func removeOnInterrupt(_ scratch: URL) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP, SIGPIPE].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            try? FileManager.default.removeItem(at: scratch)
            exit(128 + number)
        }
        source.resume()
        return source
    }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    return 1
}

exit(await labMain())
