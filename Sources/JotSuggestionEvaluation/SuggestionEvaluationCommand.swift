import JotCore
import Foundation

extension RuntimeInfo {
    static var current: RuntimeInfo {
        RuntimeInfo(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    hardwareModel: currentHardwareModel(), modelAvailability: AppleFMGeneration.availability)
    }

    private static func currentHardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

struct CommandOptions: Equatable {
    var corpusArgument: String
    var outputArgument: String
    var mode = EvaluationMode.normal
    var iterations = 1
    var sourceRevision: String?

    var corpus: URL { URL(fileURLWithPath: corpusArgument) }
    var output: URL { URL(fileURLWithPath: outputArgument) }
    /// The corpus path as given, with the home directory shown as ~.
    var corpusPath: String {
        let home = NSHomeDirectory()
        return corpusArgument.hasPrefix(home + "/") ? "~" + String(corpusArgument.dropFirst(home.count)) : corpusArgument
    }

    static let usage = """
        jot-suggestion-eval: synthetic on-device contextual-suggestion experiment

        jot-suggestion-eval --corpus <scenarios.json> --output <new-directory>
                            [--mode normal|oracle-context] [--iterations 1-20] [--source-revision <commit>]

        Reads only the synthetic corpus and writes run.json, results.jsonl and prompts.jsonl into a directory
        that must not exist yet. It never connects to Jot, reads transcripts, inserts text or runs commands.
        normal selects sources itself. oracle-context generates from the corpus's expected sources instead,
        isolating the model from retrieval; its records are labeled with that mode.
        """

    /// nil when help was requested.
    static func parse(_ arguments: [String]) throws -> CommandOptions? {
        var corpus: String?, output: String?, revision: String?
        var mode = EvaluationMode.normal, iterations = 1
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw EvaluationError.usage("\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--help", "-h":
                return nil
            case "--corpus":
                corpus = try value()
            case "--output":
                output = try value()
            case "--mode":
                let name = try value()
                guard let parsed = EvaluationMode(rawValue: name) else {
                    throw EvaluationError.usage("--mode must be normal or oracle-context")
                }
                mode = parsed
            case "--iterations":
                let text = try value()
                guard let count = Int(text), (1...20).contains(count) else {
                    throw EvaluationError.usage("--iterations must be a number from 1 to 20")
                }
                iterations = count
            case "--source-revision":
                revision = try value()
            case let other:
                throw EvaluationError.usage("unknown argument \(other)\n\n\(usage)")
            }
            index += 1
        }
        guard let corpus, let output else { throw EvaluationError.usage("--corpus and --output are required\n\n\(usage)") }
        return CommandOptions(corpusArgument: corpus, outputArgument: output, mode: mode, iterations: iterations,
                              sourceRevision: revision)
    }
}

@main
struct SuggestionEvaluationCommand {
    @MainActor
    static func main() async {
        do {
            guard let options = try CommandOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
                print(CommandOptions.usage)
                return
            }
            let status = try await run(options, generator: { try await AppleFMGeneration.generate($0) },
                                       generatorLabel: "apple-fm", runtime: .current)
            exit(status)
        } catch {
            FileHandle.standardError.write(Data("jot-suggestion-eval: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Returns 0 when every scenario ran and 3 when the run stopped early to avoid overlapping requests.
    @MainActor
    static func run(_ options: CommandOptions, generator: @escaping ModelCallGate.Generator, generatorLabel: String,
                    runtime: RuntimeInfo) async throws -> Int32 {
        let data = try Data(contentsOf: options.corpus)
        let corpus = try Corpus.decode(data)
        let output = try EvaluationOutput(creating: options.output)
        let configuration = EvaluationConfiguration(mode: options.mode, iterations: options.iterations,
                                                    generatorLabel: generatorLabel)
        var metadata = RunMetadata(configuration: configuration, corpus: corpus, corpusPath: options.corpusPath,
                                   corpusSHA256: ContentHash.sha256(data), sourceRevision: options.sourceRevision,
                                   runtime: runtime, startedAt: Date())
        try output.writeRun(metadata)
        let evaluation = SuggestionEvaluation(configuration: configuration, generator: generator)
        var outcomes: [String: Int] = [:]
        try await evaluation.run(corpus) { record in
            try output.append(record)
            metadata.recordCount += 1
            outcomes[record.outcome.rawValue, default: 0] += 1
        }
        metadata.stopReason = evaluation.stopReason
        metadata.finishedAt = Date()
        try output.writeRun(metadata)
        let summary = outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("Wrote \(metadata.recordCount) \(configuration.mode.rawValue) records to \(options.outputArgument) (\(summary)). Scores stay null until a person reviews the outputs.")
        if let reason = evaluation.stopReason {
            FileHandle.standardError.write(Data("jot-suggestion-eval: stopped early. \(reason)\n".utf8))
            return 3
        }
        return 0
    }
}
