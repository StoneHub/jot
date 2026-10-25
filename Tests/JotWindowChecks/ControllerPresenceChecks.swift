import AppKit
import Combine
import Darwin
import JotCore

/// Synthetic lifecycle hints plus a real child exit; no host or capture is started.
enum ControllerPresenceChecks {
    @MainActor final class Fixture {
        var helpers: Set<pid_t> = []
        var reads = 0
        var exits: [pid_t: @MainActor @Sendable () -> Void] = [:]
        var cancelled: Set<pid_t> = []
    }

    enum Failure: Error { case failed(String) }

    @MainActor static func run() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.failed(message) }
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        let center = NotificationCenter(), hints = NotificationCenter()
        let fixture = Fixture()
        var presence: JotControllerPresence? = JotControllerPresence(center: center, controllerEvents: hints,
            controllerProcesses: { fixture.reads += 1; return fixture.helpers },
            observeExit: { pid, handler in
                fixture.exits[pid] = handler
                return AnyCancellable { MainActor.assumeIsolated { _ = fixture.cancelled.insert(pid) } }
            })
        try require(presence!.showsIcon(alwaysShow: false), "Missing controller must leave controls accessible")
        let initialReads = fixture.reads
        RunLoop.main.run(until: Date().addingTimeInterval(3.3))
        try require(fixture.reads == initialReads, "Idle controller detection still polls")
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try require(fixture.reads == initialReads, "Unrelated applications triggered controller discovery")
        hints.post(name: ControlEvents.controllerChanged, object: nil, userInfo: ["running": true, "pid": 999])
        try require(settle { fixture.reads > initialReads }, "Lifecycle hint was not observed")
        try require(!presence!.isRunning, "Unverified notification payload changed controller state")

        fixture.helpers = [101, 102]
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        try require(settle { presence!.isRunning && fixture.exits.count == 2 }, "Helper start did not arm exit observations")
        try require(!presence!.showsIcon(alwaysShow: false) && presence!.showsIcon(alwaysShow: true),
                    "Controller state or explicit icon preference was lost")
        fixture.exits[101]?()
        try require(presence!.isRunning && fixture.cancelled.contains(101), "One helper exit hid another active controller")
        fixture.exits[102]?()
        try require(!presence!.isRunning && presence!.showsIcon(alwaysShow: false), "Last helper exit did not restore controls")
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try require(!presence!.isRunning, "A stale child snapshot revived an exited helper")
        fixture.helpers = []
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        fixture.helpers = [101]
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        try require(settle { presence!.isRunning }, "A reaped process ID could not be reused")
        fixture.helpers = []
        fixture.exits[101]?()
        fixture.helpers = [103]
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        try require(settle { presence!.isRunning }, "Feature re-enable inside a running host was missed")
        presence = nil
        try require(fixture.cancelled.contains(103), "Presence teardown retained observers or process watches")
        let stoppedReads = fixture.reads
        hints.post(name: ControlEvents.controllerChanged, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try require(fixture.reads == stoppedReads, "Events kept a retired presence owner alive")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let realExit = JotControllerPresence(center: center, controllerEvents: hints,
            controllerProcesses: { child.isRunning ? [child.processIdentifier] : [] })
        try require(realExit.isRunning, "Already-running helper was not discovered at startup")
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        try require(settle { !realExit.isRunning }, "Kernel process-exit observation missed an abrupt exit")
        print("PASS: no idle controller polling; verified lifecycle hints; multiple-helper/last-exit fallback; preference override; observer teardown; real abrupt process exit.")
    }
}
