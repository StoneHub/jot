import Foundation

/// `jot lab` hands its arguments to the `jot-lab` helper beside this executable. The helper links the app's recognition
/// code, which this CLI does not, and runs in its own process, so the running app keeps listening.
enum LabCommand {
    static func run(_ args: [String]) throws -> Never {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { throw CLIError.usage("Cannot locate the jot executable.") }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("jot-lab")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CLIError.usage("jot lab needs \(helper.path); install a Jot build that includes it.")
        }
        let argv = ([helper.path] + args).map { strdup($0) } + [nil]
        execv(helper.path, argv)
        throw CLIError.usage("Could not start \(helper.path): \(String(cString: strerror(errno)))")
    }
}
