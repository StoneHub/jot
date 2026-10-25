import AppKit
import Combine
import Darwin
import JotCore

/// Host/helper events invalidate a verified process snapshot. No timer runs while
/// Jot is idle, and an exit observer restores standalone controls after a crash.
@MainActor
final class JotControllerPresence: ObservableObject {
    typealias ExitObserver = @MainActor (pid_t, @escaping @MainActor @Sendable () -> Void) -> AnyCancellable
    @Published private(set) var isRunning = false
    private var observations: [AnyCancellable] = []
    private var processes: [pid_t: AnyCancellable] = [:]
    private var exited: Set<pid_t> = []
    private let controllerProcesses: @MainActor () -> Set<pid_t>
    private let observeExit: ExitObserver

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         controllerEvents: NotificationCenter = DistributedNotificationCenter.default(),
         controllerProcesses: @escaping @MainActor () -> Set<pid_t> = { JotControllerPresence.vorssaintHelpers() },
         observeExit: @escaping ExitObserver = { pid, handler in JotControllerPresence.observeExit(pid, handler: handler) }) {
        self.controllerProcesses = controllerProcesses
        self.observeExit = observeExit
        observations.append(center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification),
                   center.publisher(for: NSWorkspace.didWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard notification.name == NSWorkspace.didWakeNotification ||
                            app?.bundleIdentifier?.hasPrefix("com.vorssaint.utils") == true else { return }
                    self?.refresh()
                }
            })
        observations.append(controllerEvents.publisher(for: ControlEvents.controllerChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        observations.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        // Subscribe before reading so a helper starting during app launch cannot
        // fall between initial discovery and event registration.
        refresh()
    }

    func showsIcon(alwaysShow: Bool) -> Bool { alwaysShow || !isRunning }

    /// Only this app's sealed helper, directly owned by a Vorssaint host, counts.
    /// Distributed notifications are hints; their payload never changes state.
    static func vorssaintHelpers(helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/jot-vorssaint")) -> Set<pid_t> {
        let target = helper.resolvingSymlinksInPath().path
        var matches: Set<pid_t> = []
        for host in NSWorkspace.shared.runningApplications {
            guard !host.isTerminated, host.bundleIdentifier?.hasPrefix("com.vorssaint.utils") == true else { continue }
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(host.processIdentifier, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            for child in children.prefix(Int(max(0, count))) {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let length = proc_pidpath(child, &path, UInt32(path.count))
                if length > 0 && String(decoding: path.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self) == target {
                    matches.insert(child)
                }
            }
        }
        return matches
    }

    static func observeExit(_ pid: pid_t, handler: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { Task { @MainActor in handler() } }
        source.activate()
        // Cover an exit between discovery and arming the kernel observation.
        if kill(pid, 0) != 0 && errno == ESRCH { Task { @MainActor in handler() } }
        return AnyCancellable { source.cancel() }
    }

    private func refresh() {
        let snapshot = controllerProcesses()
        // A terminated child can remain in the parent's process snapshot until
        // reaped. Its one-shot exit event is authoritative during that interval.
        exited.formIntersection(snapshot)
        let current = snapshot.subtracting(exited)
        for pid in processes.keys where !current.contains(pid) { processes.removeValue(forKey: pid) }
        for pid in current where processes[pid] == nil {
            processes[pid] = observeExit(pid) { [weak self] in
                guard let self else { return }
                self.exited.insert(pid)
                self.refresh()
            }
        }
        let running = !current.isEmpty
        if running != isRunning { isRunning = running }
    }
}
