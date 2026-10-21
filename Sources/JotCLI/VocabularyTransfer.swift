import Foundation
import JotCore

/// `jot vocabulary export` and `jot vocabulary import <file>`: move personal vocabulary to another Mac, and later to Jot
/// for Android, in the file docs/SHARED-CONTRACT.md describes. The file goes only where the user puts it. Import adds
/// one `vocabulary.save` each, so the app checks and applies every entry exactly as `jot vocabulary add` does.
enum VocabularyTransfer {
    static let use = "Use: jot vocabulary export > <file.json>, or jot vocabulary import <file.json | ->"

    static func run(_ args: [String]) throws {
        switch (args.first, args.count) {
        case ("export"?, 1):
            FileHandle.standardOutput.write(try VocabularyFile.encode(current().entries))
        case ("import"?, 2):
            let handle = try args[1] == "-" ? FileHandle.standardInput
                : FileHandle(forReadingFrom: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
            let data = try handle.read(upToCount: VocabularyFile.maximumBytes + 1) ?? Data()
            let plan = try VocabularyFile.additions(VocabularyFile.decode(data), to: current())
            for (index, entry) in plan.added.enumerated() {
                let response = try request(.vocabularySave, ["preferred": entry.preferred, "heard": entry.heard, "enabled": entry.enabled])
                guard response["ok"] as? Bool == true else {
                    throw CLIError.usage("Added \(index) of \(plan.added.count) entries, then Jot refused \(entry.preferred): \((response["error"] as? String) ?? "no reason given")")
                }
            }
            print("Added \(plan.added.count) \(plan.added.count == 1 ? "entry" : "entries"); skipped \(plan.skipped) whose phrase Jot already has.")
        default: throw CLIError.usage(use)
        }
    }

    /// The list the app holds now. Refuses when the app could not load it, so an export never writes an empty file in its place.
    private static func current() throws -> PersonalVocabulary {
        let response = try request(.vocabularyList, [:])
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] else {
            throw CLIError.usage((response["error"] as? String) ?? "Jot did not return the vocabulary.")
        }
        if let loadError = result["loadError"] as? String { throw CLIError.usage(loadError) }
        guard let listed = result["entries"] as? [Any] else { throw CLIError.usage("Jot did not return the vocabulary.") }
        let entries = try JSONDecoder().decode([VocabularyEntry].self, from: JSONSerialization.data(withJSONObject: listed))
        var vocabulary = PersonalVocabulary()
        for entry in entries { try vocabulary.save(entry) }
        return vocabulary
    }

    private static func request(_ method: LocalMethod, _ params: [String: Any]) throws -> [String: Any] {
        let data = try LocalServiceClient().request(method, params: params)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
