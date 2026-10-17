import AppKit
import Combine

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
             NSRunningApplication.runningApplications(withBundleIdentifier: "space.monroe.JotBar")
                 .contains { !$0.isTerminated }
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

    private func refresh() {
        let running = controllerIsRunning()
        if running != isRunning { isRunning = running }
    }
}
