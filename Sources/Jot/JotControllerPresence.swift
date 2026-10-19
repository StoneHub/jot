import AppKit
import Combine
import Darwin

/// Hiding the standalone icon must never leave Jot without menu bar controls.
/// Workspace events give an immediate hint; a slow reconciliation also covers
/// missed notifications or an abnormal controller exit.
@MainActor
final class JotControllerPresence: ObservableObject {
    @Published private(set) var isRunning = false
    private var observation: AnyCancellable?
    private var reconciliation: AnyCancellable?
    private let controllerIsRunning: @MainActor () -> Bool

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         controllerIsRunning: @escaping @MainActor () -> Bool = {
             // The retired Vorssaint+Jot app stays recognized while it is still installed.
             NSRunningApplication.runningApplications(withBundleIdentifier: "space.monroe.JotBar").contains { !$0.isTerminated }
                 || JotControllerPresence.vorssaintRunsJot()
         }) {
        self.controllerIsRunning = controllerIsRunning
        observation = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        reconciliation = Timer.publish(every: 3, tolerance: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        refresh()
    }

    func showsIcon(alwaysShow: Bool) -> Bool { alwaysShow || !isRunning }

    /// Vorssaint runs Jot's own sealed helper only while its Jot feature is on,
    /// and the helper exits with it, so that live child is the controller.
    /// Vorssaint merely running, with the feature off, leaves the icon alone.
    static func vorssaintRunsJot(helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/jot-vorssaint")) -> Bool {
        let target = helper.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains { host in
            guard !host.isTerminated, host.bundleIdentifier?.hasPrefix("com.vorssaint.utils") == true else { return false }
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(host.processIdentifier, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            return children.prefix(Int(max(0, count))).contains { child in
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                let length = proc_pidpath(child, &path, UInt32(path.count))
                return length > 0 && String(decoding: path.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self) == target
            }
        }
    }

    private func refresh() {
        let running = controllerIsRunning()
        if running != isRunning { isRunning = running }
    }
}
