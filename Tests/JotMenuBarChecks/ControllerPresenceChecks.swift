import AppKit

@main
struct ControllerPresenceChecks {
    @MainActor
    final class Fixture {
        var running = false
        var reads = 0
    }

    @MainActor
    static func main() {
        let center = NotificationCenter()
        let fixture = Fixture()
        let presence = JotControllerPresence(center: center, controllerIsRunning: {
            fixture.reads += 1
            return fixture.running
        })
        precondition(presence.showsIcon(alwaysShow: false), "No controller at launch must leave Jot accessible")
        precondition(presence.showsIcon(alwaysShow: true))

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

        let alreadyRunning = JotControllerPresence(center: center, controllerIsRunning: { true })
        precondition(!alreadyRunning.showsIcon(alwaysShow: false), "Detect an already-running controller at Jot launch")
        print("Controller presence checks passed: initial state, launch, unrelated exit, controller exit, relaunch, preference override")
    }
}
