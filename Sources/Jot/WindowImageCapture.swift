import AppKit
import JotCore
import ScreenCaptureKit

/// One image of the window around the field, for a suggestion that asked for it. The image stays in memory for that
/// request and is never saved; only an outcome and a duration reach diagnostics. The window must match the field's own
/// window, as Accessibility reports it, or no image is taken.
struct WindowImageCapture: Sendable {
    let pid: pid_t
    /// Accessibility's frame for the field's window, when it reports one.
    let window: CGRect?
    let field: CGRect

    struct Result: Sendable {
        let image: CGImage?
        let timedOut: Bool
        let milliseconds: Int
    }

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time. After that, only System Settings can allow it.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `capture()`, timed, given up once `limit` passes.
    @MainActor
    func capture(within limit: Duration) async -> Result {
        let began = Date()
        let task = Task.detached(priority: .userInitiated) { await self.capture() }
        let finished = await ModelCallGate.value(of: task, within: limit)
        let milliseconds = min(60_000, max(0, Int(Date().timeIntervalSince(began) * 1_000)))
        guard let finished else { return Result(image: nil, timedOut: true, milliseconds: milliseconds) }
        return Result(image: finished, timedOut: false, milliseconds: milliseconds)
    }

    /// The field's window from its top to the bottom of the field, in the field's column. Nil when the window cannot
    /// be told apart from the app's others or cannot be captured.
    func capture() async -> CGImage? {
        guard !Task.isCancelled, Self.permitted, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        guard !Task.isCancelled else { return nil }
        let windows = content.windows.map {
            WindowImageGeometry.Window(id: $0.windowID, pid: $0.owningApplication?.processID ?? 0, frame: $0.frame, layer: $0.windowLayer)
        }
        guard let match = WindowImageGeometry.window(among: windows, pid: pid, windowFrame: window, field: field),
              let target = content.windows.first(where: { $0.windowID == match.id }),
              let region = WindowImageGeometry.region(window: match.frame, field: field) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        guard let size = WindowImageGeometry.pixelSize(of: match.frame.size, scale: CGFloat(filter.pointPixelScale)) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        // Without the shadow, the image's edges are the window's frame, which the region is measured from.
        configuration.ignoreShadowsSingleWindow = true
        guard !Task.isCancelled, Self.permitted, let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let pixels = WindowImageGeometry.pixelRegion(region, window: match.frame.size, image: (width: image.width, height: image.height))
        else { return nil }
        guard !Task.isCancelled else { return nil }
        return image.cropping(to: pixels)
    }
}
