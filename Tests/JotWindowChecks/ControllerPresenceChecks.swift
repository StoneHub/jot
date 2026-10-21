import AppKit

/// Run by JotWindowChecks when JOT_CONTROLLER_PRESENCE_CHECKS=1; add --live to watch a real controller quit and relaunch.
enum ControllerPresenceChecks {
    @MainActor
    final class Fixture {
        var running = false
        var reads = 0
    }

    static let key = "showMenuBarIcon"

    @MainActor
    static func run() {
        if CommandLine.arguments.contains("--live") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let defaults = UserDefaults(suiteName: "ControllerPresenceChecks.live")!
            defaults.set(false, forKey: key)
            let presence = JotControllerPresence(defaults: defaults, alwaysShowKey: key)
            let initial = presence.isRunning
            var states = [initial]
            FileHandle.standardOutput.write(Data("Initial controller presence: \(initial)\n".utf8))
            let deadline = Date().addingTimeInterval(60)
            while states.count < 3 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if presence.isRunning != states.last {
                    states.append(presence.isRunning)
                    FileHandle.standardOutput.write(Data("Controller presence: \(presence.isRunning)\n".utf8))
                }
            }
            precondition(states == [initial, !initial, initial], "Expected a real controller exit and relaunch")
            print("Live workspace presence transitions: \(states); fallback icon: \(states.map { !$0 })")
            return
        }
        let center = NotificationCenter()
        let fixture = Fixture()
        let defaults = UserDefaults(suiteName: "ControllerPresenceChecks")!
        defaults.removePersistentDomain(forName: "ControllerPresenceChecks")
        let presence = JotControllerPresence(center: center, defaults: defaults, alwaysShowKey: key, controllerIsRunning: {
            fixture.reads += 1
            return fixture.running
        })
        precondition(presence.showsIcon(alwaysShow: false), "No controller at launch must leave Jot accessible")
        precondition(presence.showsIcon(alwaysShow: true))

        func settle(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        precondition(!presence.isReconciling, "Always show (the default) needs no polling")
        defaults.set(false, forKey: key)
        precondition(settle { presence.isReconciling }, "Turning always-show off must start reconciliation")
        defaults.set(true, forKey: key)
        precondition(settle { !presence.isReconciling }, "Turning always-show on must stop reconciliation")

        func notify(_ name: Notification.Name) {
            let previous = fixture.reads
            center.post(name: name, object: nil)
            let deadline = Date().addingTimeInterval(1)
            while fixture.reads == previous && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(fixture.reads > previous, "Workspace event must refresh controller presence")
        }

        fixture.running = true
        notify(NSWorkspace.didLaunchApplicationNotification)
        precondition(!presence.showsIcon(alwaysShow: false), "Controller launch must remove the duplicate icon")
        precondition(presence.showsIcon(alwaysShow: true), "Explicit always-show preference must win")

        notify(NSWorkspace.didTerminateApplicationNotification)
        precondition(!presence.showsIcon(alwaysShow: false), "Another app quitting must not imply the controller quit")

        fixture.running = false
        notify(NSWorkspace.didTerminateApplicationNotification)
        precondition(presence.showsIcon(alwaysShow: false), "Controller exit or crash must restore Jot's icon")

        fixture.running = true
        notify(NSWorkspace.didLaunchApplicationNotification)
        precondition(!presence.showsIcon(alwaysShow: false), "Fallback must not overwrite the hidden preference")

        let alreadyRunning = JotControllerPresence(center: center, defaults: defaults, alwaysShowKey: key, controllerIsRunning: { true })
        precondition(!alreadyRunning.showsIcon(alwaysShow: false), "Detect an already-running controller at Jot launch")
        print("Controller presence checks passed: initial state, launch, unrelated exit, controller exit, relaunch, preference override, polling only while always-show is off")
    }
}
