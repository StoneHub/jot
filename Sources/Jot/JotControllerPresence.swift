import AppKit
import Combine

/// Hiding the standalone icon must never leave Jot without menu bar controls.
/// Workspace notifications also cover a controller crash; no polling is needed.
@MainActor
final class JotControllerPresence: ObservableObject {
    @Published private(set) var isRunning = false
    private var observation: AnyCancellable?
    private let controllerIsRunning: @MainActor () -> Bool

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         controllerIsRunning: @escaping @MainActor () -> Bool = {
             NSWorkspace.shared.runningApplications.contains {
                 $0.bundleIdentifier == "space.monroe.JotBar" && !$0.isTerminated
             }
         }) {
        self.controllerIsRunning = controllerIsRunning
        observation = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        refresh()
    }

    func showsIcon(alwaysShow: Bool) -> Bool { alwaysShow || !isRunning }

    private func refresh() { isRunning = controllerIsRunning() }
}
