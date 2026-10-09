import Foundation
import JotCore

/// `jot settings import <variants.json> <name>`: applies one lab variant's settings to the running app, one `settings.set`
/// each, so the app validates and applies them exactly as `jot settings set` does. Reads a variants file or `jot lab`'s output.
enum SettingsImport {
    static func requests(_ data: Data, variant name: String) throws -> [[String: Any]] {
        guard let variant = try LabVariant.parse(data).first(where: { $0.name == name }) else {
            throw CLIError.usage("No variant named \(name) in that file.")
        }
        guard !variant.settings.isEmpty else { throw CLIError.usage("\(name) changes no settings; nothing to import.") }
        return variant.settings.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .bool(let value): ["key": key, "value": value]
            case .number(let value): ["key": key, "value": value]
            case .text(let value): ["key": key, "value": value]
            }
        }
    }

    static func run(_ args: [String]) throws {
        guard args.count == 2 else { throw CLIError.usage("Use: jot settings import <variants.json> <variant name>") }
        let url = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
        for params in try requests(Data(contentsOf: url), variant: args[1]) {
            let data = try LocalServiceClient().request(method: "settings.set", params: params)
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard response?["ok"] as? Bool == true else {
                throw CLIError.usage("\(params["key"] ?? ""): \((response?["error"] as? String) ?? "the app refused it")")
            }
            print("\(params["key"] ?? "") = \(params["value"] ?? "")")
        }
    }
}
