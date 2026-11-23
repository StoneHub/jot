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

        /// Printed whole by the tool's `FAIL: \(error)`, so each case says what to do instead of only its name.
        enum Failure: Error, LocalizedError, CustomStringConvertible {
            case usage(String), accessibility, timeout(String), unexpected(String)
            var description: String { errorDescription ?? "insertion matrix failed" }
            var errorDescription: String? {
                switch self {
                case .usage(let message): return message
                case .accessibility:
                    return "Accessibility is not granted to the terminal app running this check (echo $TERM_PROGRAM names it). "
                        + "Switch it on in System Settings → Privacy & Security → Accessibility, quit and reopen it, then run again."
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
            if report.rows.contains(where: { $0.result == "failed" }) { exit(1) }
        }

        // MARK: One row

        static func check(_ target: String, electron: (bundle: String, new: String?)?, phrase: String, pages: Pages) async -> Row {
            var row = Row(target: target, expected: refused.contains(target) ? "refused" : "verified", result: "failed")
            var field: AXUIElement?
            var pid: pid_t = 0
            do {
                let app = try open(target, electron: electron, pages: pages)
                pid = app.processIdentifier
                row.app = app.bundleIdentifier ?? app.localizedName
                // The app does this when an app comes to the front: Electron keeps its tree off until asked.
                DictationInput.wakeAccessibility(app.processIdentifier)
                let input = DictationInput(onStart: {}, onStop: { _ in })
                let want: Want = target == "password" ? .secure : target == "electron" ? .anyEditable : .textArea
                let captured = await capture(input, app: app, want: want, timeout: target == "electron" ? 45 : 15)
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
                case .captured(let held):
                    field = held
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
            } catch DictationInput.InputError.targetChanged where field != nil {
                // Jot gave up on a field that had held focus for a second. Say why it might have: another app in front,
                // focus really moving, or the app not answering within the 5 ms Jot allows each focus check.
                row.note = DictationInput.InputError.targetChanged.localizedDescription + " " + diagnose(field!, pid: pid)
            } catch {
                row.note = error.localizedDescription
            }
            return row
        }

        enum Capture {
            case captured(AXUIElement)
            case refused(role: String?, subrole: String?)
            case notEditable(Error)
        }

        /// The kind of field a row waits for. TextEdit, the Safari textarea and Terminal focus a text area; Safari starts
        /// in its address bar, a text field, and TextEdit may show its Open panel first, so a text field is not enough.
        enum Want { case textArea, secure, anyEditable }

        /// Waits until the app is in front and the same field of the wanted kind has kept focus for about a second, then
        /// captures it as the app does at a key press. Capturing while a window or page is still settling loses the target
        /// to Jot's own focus-change guard, which is what a person never sees: they start dictating into a field that holds
        /// still. A password field the row wants ends the wait as a refusal. On a timeout the note says what had focus.
        static func capture(_ input: DictationInput, app: NSRunningApplication, want: Want, timeout: Double) async -> Capture {
            let pid = app.processIdentifier
            let deadline = ContinuousClock.now + .seconds(timeout)
            var lastActivation = ContinuousClock.now
            var returned = 0
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.5)
            var previous: AXUIElement?
            var steady = 0
            var seen = "the app never came to the front"
            while ContinuousClock.now < deadline {
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != pid {
                    seen = "\(front?.localizedName ?? "no app") was in front instead" + (returned > 0 ? " (brought the app back \(returned) times)" : "")
                    previous = nil; steady = 0
                    // A notification or another app can take the front mid-run; bring the row's app back, at most every 2 s.
                    if ContinuousClock.now - lastActivation > .seconds(2) {
                        lastActivation = ContinuousClock.now
                        returned += 1
                        activate(app)
                    }
                } else if let field = DictationInput.focusedField(application) {
                    // Electron turns its tree on only when asked, and may turn it on late; asking again is harmless.
                    DictationInput.wakeAccessibility(pid)
                    AXUIElementSetMessagingTimeout(field, 0.5)
                    let role = DictationInput.stringAttribute(field, kAXRoleAttribute)
                    let subrole = DictationInput.stringAttribute(field, kAXSubroleAttribute)
                    let kind = [role, subrole].compactMap { $0 }.joined(separator: "/")
                    seen = "focus was on \(kind.isEmpty ? "an element with no role" : kind)"
                    let secure = subrole == kAXSecureTextFieldSubrole
                    let wanted: Bool
                    switch want {
                    case .secure: wanted = secure
                    case .textArea: wanted = !secure && role == kAXTextAreaRole
                    case .anyEditable: wanted = !secure && [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "")
                    }
                    if wanted, let held = previous, CFEqual(held, field) { steady += 1 } else { steady = wanted ? 1 : 0 }
                    previous = wanted ? field : nil
                    if steady >= 4 {
                        do {
                            try input.captureTarget()
                            return .captured(field)
                        } catch DictationInput.InputError.secureField {
                            return .refused(role: role, subrole: subrole)
                        } catch {
                            seen = error.localizedDescription
                            previous = nil; steady = 0
                        }
                    }
                } else {
                    seen = "nothing in the app had focus"
                    previous = nil; steady = 0
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return .notEditable(Failure.timeout("no \(want == .secure ? "password" : "editable") field held focus within \(Int(timeout)) s; \(seen)"))
        }

        /// Brings an app to the front through Apple Events, which macOS allows from the terminal running the check.
        static func activate(_ app: NSRunningApplication) {
            if let bundle = app.bundleIdentifier {
                do { try osascript("tell application id \"\(bundle)\" to activate"); return } catch {}
            }
            app.activate()
        }

        /// Why Jot may have dropped a field that had held focus: what is in front, whether focus moved, and how many quick
        /// focus reads the app answers within Jot's 5 ms limit. A slow answer reads as a focus change by design.
        static func diagnose(_ captured: AXUIElement, pid: pid_t) -> String {
            var facts: [String] = []
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != pid { facts.append("\(front?.localizedName ?? "no app") was in front") }
            let patient = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(patient, 0.5)
            if let now = DictationInput.focusedField(patient) {
                AXUIElementSetMessagingTimeout(now, 0.5)
                let kind = [DictationInput.stringAttribute(now, kAXRoleAttribute), DictationInput.stringAttribute(now, kAXSubroleAttribute)]
                    .compactMap { $0 }.joined(separator: "/")
                facts.append(CFEqual(now, captured) ? "the captured field still had focus" : "focus had moved to \(kind.isEmpty ? "another element" : kind)")
            } else {
                facts.append("nothing had focus")
            }
            let quick = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(quick, 0.005)
            let answered = (0..<10).filter { _ in DictationInput.focusedField(quick) != nil }.count
            facts.append("\(answered) of 10 focus reads answered within 5 ms")
            return "(" + facts.joined(separator: "; ") + ")"
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
                    DictationInput.wakeAccessibility(app.processIdentifier)
                    try osascript("tell application id \"\(electron.bundle)\" to activate")
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
                           "close (every document whose text contains \"\(windowTitle)\") saving no",
                           "try", "close (every document whose text is \"\" and path is missing value) saving no", "end try",
                           "end tell")
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
    }
}
