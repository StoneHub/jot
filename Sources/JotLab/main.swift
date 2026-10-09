import Foundation
import JotCore

/// `jot-lab <audio> --variants <file> --out <dir> [--captions <file>]`, launched by `jot lab`.
@MainActor
func labMain() async -> Int32 {
    let usage = "Use: jot lab <audio> --variants <file.json> --out <dir> [--captions <file.srt|.vtt>]"
    var arguments = Array(CommandLine.arguments.dropFirst())
    var options: [String: String] = [:]
    var positional: [String] = []
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        if ["--variants", "--out", "--captions"].contains(argument) {
            guard !arguments.isEmpty else { return fail(usage) }
            options[argument] = arguments.removeFirst()
        } else if argument.hasPrefix("--") {
            return fail("Unknown option \(argument). \(usage)")
        } else {
            positional.append(argument)
        }
    }
    guard positional.count == 1, let variantsPath = options["--variants"], let outPath = options["--out"] else { return fail(usage) }
    let audio = url(positional[0]), output = url(outPath)
    do {
        guard FileManager.default.isReadableFile(atPath: audio.path) else { throw LabError.invalid("Cannot read \(audio.path).") }
        let variants = try LabVariant.parse(Data(contentsOf: url(variantsPath)))
        let captions = try options["--captions"].map { try LabCaptions.parse(String(contentsOf: url($0), encoding: .utf8)) }
        try prepareOutput(output)
        // Private working files go to the user's temporary folder and are removed even when the run fails.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jot-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let interrupts = removeOnInterrupt(scratch)
        defer { interrupts.forEach { $0.cancel() } }
        let lab = TuningLab(audio: audio, variants: variants, captions: captions, scratch: scratch,
            base: UserDefaults(suiteName: "space.jot.app"), log: { print($0); fflush(stdout) })
        let results = try await lab.run()
        try LabReport.json(results).write(to: output.appendingPathComponent("variants.json"))
        try LabReport.html(audioName: audio.lastPathComponent, variants: results).write(to: output.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        for result in results {
            let score = result.score.map { String(format: ", WER %.1f%% raw, %.1f%% cleaned", $0.raw.rate * 100, $0.cleaned.rate * 100) } ?? ""
            print("\(result.name): \(result.rows.count) rows, \(result.paragraphs.count) paragraphs, \(Set(result.rows.compactMap(\.passSpeaker)).count) pass speakers\(score)")
        }
        print("Wrote \(output.appendingPathComponent("report.html").path) and variants.json.")
        return 0
    } catch {
        return fail(error.localizedDescription)
    }
}

/// Recordings and their transcripts are private: the output goes to an empty folder outside any git repository.
func prepareOutput(_ output: URL) throws {
    var directory = output.standardizedFileURL
    while directory.path != "/" {
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

/// Ctrl-C or a termination still removes the working files, which hold the recording and its transcript.
func removeOnInterrupt(_ scratch: URL) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
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
