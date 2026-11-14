import AppKit
import ApplicationServices
import Foundation
import JotCore

/// `JotRecoveryChecks --insertion-matrix --out <file.json> [--electron <bundle id> [--electron-new <key>]] [--skip <row>]...
/// [--phrase <text>]`
///
/// The real-app insertion matrix: the same `DictationInput` code the app uses delivers one fixed phrase into real apps,
/// and a password field has to refuse it. It opens each app itself and reads the field back through Accessibility, so
/// it needs no speech and no shortcut; those stay on Monroe's own test list. Accessibility and Automation are granted
/// to the process that runs this tool, usually Terminal. `scripts/insertion_matrix.py` builds and runs it.
extension RecoveryFlowChecks {
    @MainActor enum InsertionMatrix {
        static let defaultPhrase = "Jot insertion matrix check 0427."
        /// In run order. Safari opens its two pages in one window; Terminal comes after Safari so the shell window is not
        /// hidden behind it; the Electron app is last because it may need a click.
        static let rows = ["textedit", "safari", "password", "terminal", "electron"]
        /// A row the app has to refuse: no write, the secure-field error, nothing else.
        static let refused: Set<String> = ["password"]

        struct Row: Codable {
            var target: String
            var expected: String
            var result: String
            var app: String?
            var path: String?
            var outcome: String?
            var verified: Bool?
            var role: String?
            var subrole: String?
            /// Whether the field's Accessibility value held the phrase after delivery; nil when it could not be read.
            var readback: Bool?
            var note: String?
        }

        struct Report: Codable {
            var phrase: String
            var rows: [Row]
        }

        enum Failure: Error, LocalizedError {
            case usage(String), accessibility, timeout(String), unexpected(String)
            var errorDescription: String? {
                switch self {
                case .usage(let message): return message
                case .accessibility:
                    return "Accessibility is not granted to the app running this check (usually Terminal). "
                        + "Open System Settings → Privacy & Security → Accessibility, add it, then run again."
                case .timeout(let message): return message
                case .unexpected(let message): return message
                }
            }
        }

        static func run(_ arguments: [String]) async throws {
            var arguments = arguments
            var out: String?, electron: String?, electronNew: String?, phrase = defaultPhrase
            var skipped: Set<String> = []
            while !arguments.isEmpty {
                let argument = arguments.removeFirst()
                guard ["--out", "--electron", "--electron-new", "--skip", "--phrase"].contains(argument), !arguments.isEmpty else {
                    throw Failure.usage("Use: JotRecoveryChecks --insertion-matrix --out <file.json> [--electron <bundle id> [--electron-new <key>]] [--skip <row>]... [--phrase <text>]")
                }
                let value = arguments.removeFirst()
                switch argument {
                case "--out": out = value
                case "--electron": electron = value
                case "--electron-new":
                    guard value.count == 1, value.allSatisfy(\.isLetter) else { throw Failure.usage("--electron-new takes one letter, the Command key shortcut that opens a fresh field (n for a new file).") }
                    electronNew = value.lowercased()
                case "--phrase": phrase = value
                default:
                    guard rows.contains(value) else { throw Failure.usage("Unknown row \(value); rows are \(rows.joined(separator: ", ")).") }
                    skipped.insert(value)
                }
            }
            guard let out else { throw Failure.usage("--out <file.json> is required.") }
            guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !phrase.contains("\n") else {
                throw Failure.usage("The phrase must be one non-empty line.")
            }
            guard DictationInput.accessibilityGranted else { throw Failure.accessibility }
            let pages = try Pages()
            defer { pages.remove() }
            var report = Report(phrase: phrase, rows: [])
            for target in rows {
                let expected = refused.contains(target) ? "refused" : "verified"
                if skipped.contains(target) {
                    report.rows.append(Row(target: target, expected: expected, result: "skipped", note: "skipped by --skip"))
                } else if target == "electron", electron == nil {
                    report.rows.append(Row(target: target, expected: expected, result: "skipped", note: "pass --electron <bundle id>"))
                } else {
                    print("\(target): opening…")
                    report.rows.append(await check(target, electron: electron.map { (bundle: $0, new: electronNew) }, phrase: phrase, pages: pages))
                }
                let row = report.rows[report.rows.count - 1]
                print("\(target): \(row.result)\(row.note.map { " (\($0))" } ?? "")")
            }
            cleanUp()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: out))
            print(table(report.rows))
            if report.rows.contains(where: { $0.result == "failed" }) { exit(1) }
        }

        // MARK: One row

        static func check(_ target: String, electron: (bundle: String, new: String?)?, phrase: String, pages: Pages) async -> Row {
            var row = Row(target: target, expected: refused.contains(target) ? "refused" : "verified", result: "failed")
            do {
                let app = try open(target, electron: electron, pages: pages)
                row.app = app.bundleIdentifier ?? app.localizedName
                // The app does this when an app comes to the front: Electron keeps its tree off until asked.
                DictationInput.wakeAccessibility(app.processIdentifier)
                let input = DictationInput(onStart: {}, onStop: { _ in })
                let captured = await capture(input, pid: app.processIdentifier, timeout: target == "electron" ? 45 : 15)
                switch captured {
                case .refused(let role, let subrole):
                    row.role = role; row.subrole = subrole
                    if row.expected == "refused" {
                        row.result = "passed"; row.note = "secure field refused before any write"
                    } else {
                        row.note = "refused as a password field"
                    }
                    return row
                case .notEditable(let error):
                    row.note = error.localizedDescription
                    return row
                case .captured:
                    break
                }
                if row.expected == "refused" {
                    // Nothing is written into a field that should have been refused; the capture alone is the failure.
                    input.clearTarget()
                    row.note = "a password field was captured as editable"
                    return row
                }
                let delivery = try await input.insert(phrase)
                row.path = delivery.path; row.outcome = delivery.outcome; row.verified = delivery.verified
                row.role = delivery.role; row.subrole = delivery.subrole
                // Jot's own read-back decides; a second read is recorded for the report, as some editors expose only the current line.
                row.readback = fieldHolds(phrase, pid: app.processIdentifier)
                if delivery.verified {
                    row.result = "passed"
                    if row.readback == false { row.note = "the field's value did not show the phrase on a second read" }
                } else {
                    row.note = "delivery not verified"
                }
            } catch DictationInput.InputError.secureField {
                row.note = "secure field refused during insertion"
                row.result = row.expected == "refused" ? "passed" : "failed"
            } catch {
                row.note = error.localizedDescription
            }
            return row
        }

        enum Capture {
            case captured
            case refused(role: String?, subrole: String?)
            case notEditable(Error)
        }

        /// Waits for the app to be in front with an editable field focused, up to `timeout` seconds. A password field
        /// ends the wait at once: that is the refusal the matrix wants to see.
        static func capture(_ input: DictationInput, pid: pid_t, timeout: Double) async -> Capture {
            let deadline = ContinuousClock.now + .seconds(timeout)
            var last: Error = Failure.timeout("no editable field was focused within \(Int(timeout)) s")
            while ContinuousClock.now < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    do {
                        try input.captureTarget()
                        return .captured
                    } catch DictationInput.InputError.secureField {
                        let field = DictationInput.focusedField(AXUIElementCreateApplication(pid))
                        return .refused(role: field.flatMap { DictationInput.stringAttribute($0, kAXRoleAttribute) },
                                        subrole: field.flatMap { DictationInput.stringAttribute($0, kAXSubroleAttribute) })
                    } catch {
                        last = error
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return .notEditable(last)
        }

        /// The focused field's Accessibility value after delivery. Terminal reports its whole screen, so containment is enough.
        static func fieldHolds(_ phrase: String, pid: pid_t) -> Bool? {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.5)
            guard let field = DictationInput.focusedField(application) else { return nil }
            AXUIElementSetMessagingTimeout(field, 0.5)
            guard let value = DictationInput.stringAttribute(field, kAXValueAttribute) else { return nil }
            return value.contains(phrase)
        }

        // MARK: Opening and closing the apps

        /// Brings the row's app to the front with a fresh field, and returns it. Apple Events go through `osascript`, so
        /// macOS attributes the Automation prompt to the terminal running the check.
        static func open(_ target: String, electron: (bundle: String, new: String?)?, pages: Pages) throws -> NSRunningApplication {
            switch target {
            case "textedit":
                try osascript("tell application \"TextEdit\"", "activate", "make new document", "end tell")
                return try running(bundle: "com.apple.TextEdit")
            case "safari":
                try shell("/usr/bin/open", "-a", "Safari", pages.textarea.path)
                return try running(bundle: "com.apple.Safari")
            case "password":
                try shell("/usr/bin/open", "-a", "Safari", pages.password.path)
                return try running(bundle: "com.apple.Safari")
            case "terminal":
                try osascript("tell application \"Terminal\"", "activate", "set t to do script \"\"",
                              "set custom title of t to \"\(windowTitle)\"", "end tell")
                return try running(bundle: "com.apple.Terminal")
            case "electron":
                guard let electron else { throw Failure.usage("pass --electron <bundle id>") }
                try shell("/usr/bin/open", "-b", electron.bundle)
                let app = try running(bundle: electron.bundle)
                let name = app.localizedName ?? electron.bundle
                if let key = electron.new {
                    // A fresh field without a click: Command-N opens an untitled file in Visual Studio Code and most editors.
                    let launched = Date().addingTimeInterval(20)
                    while !app.isFinishedLaunching, Date() < launched { Thread.sleep(forTimeInterval: 0.25) }
                    Thread.sleep(forTimeInterval: 1.5)
                    try osascript("tell application \"System Events\" to keystroke \"\(key)\" using command down")
                    print("electron: sent Command-\(key.uppercased()) to \(name) for a fresh field; waiting up to 45 s for it to be focused…")
                } else {
                    print("electron: click into an editable field in \(name) (for example a new untitled file); waiting up to 45 s…")
                }
                return app
            default:
                throw Failure.usage("Unknown row \(target).")
            }
        }

        static let windowTitle = "Jot insertion matrix"

        /// Closes what the matrix opened: the TextEdit document, the Safari tabs and the Terminal window. Best effort; the
        /// Electron field keeps the phrase, which the report says to remove.
        static func cleanUp() {
            try? osascript("tell application \"TextEdit\"",
                           "close (every document whose text contains \"\(windowTitle)\") saving no", "end tell")
            try? osascript("tell application \"Safari\"", "repeat with w in windows", "repeat with t in (tabs of w)", "try",
                           "if URL of t contains \"jot-insertion-matrix\" then close t", "end try", "end repeat", "end repeat", "end tell")
            try? osascript("tell application \"Terminal\"", "repeat with w in windows", "try",
                           "if custom title of selected tab of w is \"\(windowTitle)\" then close w", "end try", "end repeat", "end tell")
        }

        static func running(bundle: String) throws -> NSRunningApplication {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { return app }
                Thread.sleep(forTimeInterval: 0.25)
            }
            throw Failure.timeout("\(bundle) did not start within 20 s")
        }

        static func osascript(_ lines: String...) throws {
            try shell("/usr/bin/osascript", lines.flatMap { ["-e", $0] })
        }

        static func shell(_ executable: String, _ arguments: String...) throws { try shell(executable, arguments) }

        static func shell(_ executable: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.unexpected("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(message.isEmpty ? "exit \(process.terminationStatus)" : message)")
            }
        }

        /// Two local pages for Safari: a focused textarea, and a focused password field. The file names carry
        /// `jot-insertion-matrix` so the clean-up can find their tabs.
        struct Pages {
            let directory: URL
            let textarea: URL
            let password: URL

            init() throws {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("jot-insertion-matrix-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                textarea = directory.appendingPathComponent("jot-insertion-matrix-textarea.html")
                password = directory.appendingPathComponent("jot-insertion-matrix-password.html")
                try Self.page(title: "Jot insertion matrix: textarea",
                              field: "<textarea id=\"notes\" rows=\"6\" cols=\"60\" autofocus></textarea>").write(to: textarea, atomically: true, encoding: .utf8)
                try Self.page(title: "Jot insertion matrix: password field",
                              field: "<input id=\"secret\" type=\"password\" size=\"40\" autofocus>").write(to: password, atomically: true, encoding: .utf8)
            }

            func remove() { try? FileManager.default.removeItem(at: directory) }

            static func page(title: String, field: String) -> String {
                """
                <!doctype html>
                <html lang="en"><head><meta charset="utf-8"><title>\(title)</title></head>
                <body style="font: 15px -apple-system, sans-serif; margin: 32px">
                <p>\(title). Jot's insertion matrix opened this page; it closes it when the check ends.</p>
                <p>\(field)</p>
                </body></html>

                """
            }
        }

        static func table(_ rows: [Row]) -> String {
            var lines = ["| Row | Expected | Result | Path | Outcome | Role | Note |", "| --- | --- | --- | --- | --- | --- | --- |"]
            for row in rows {
                let role = [row.role, row.subrole].compactMap { $0 }.joined(separator: "/")
                lines.append("| \(row.target) | \(row.expected) | \(row.result) | \(row.path ?? "–") | \(row.outcome ?? "–") | \(role.isEmpty ? "–" : role) | \(row.note ?? "") |")
            }
            return lines.joined(separator: "\n")
        }
    }
}
