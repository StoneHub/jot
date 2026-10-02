import Foundation

/// Which window a suggestion's optional image comes from, and which part of it. Like `ScreenContext`, the image keeps
/// what is above the field in a widened column; the field itself is included. The widening can include adjacent content.
/// Frames are global points from the top left of the primary display, as both Accessibility and ScreenCaptureKit report
/// them. Pure, so it can be checked without a screen.
public enum WindowImageGeometry {
    public struct Window: Equatable, Sendable {
        public init(id: UInt32, pid: Int32, frame: CGRect, layer: Int) {
            self.id = id; self.pid = pid; self.frame = frame; self.layer = layer
        }
        public let id: UInt32
        public let pid: Int32
        public let frame: CGRect
        public let layer: Int
    }

    /// The longer side of the captured window, in pixels, before the region is cut from it. The model scales images
    /// itself; a smaller capture is quicker.
    public static let maximumSide = 2_048
    /// Points a frame may differ between Accessibility and the capture list for the same window.
    static let frameTolerance: CGFloat = 8

    /// The app's ordinary window whose frame matches the field's window. Without that frame, the one ordinary window of
    /// the app containing the field. Nil when none or several match, so an image never comes from the wrong window.
    public static func window(among windows: [Window], pid: Int32, windowFrame: CGRect?, field: CGRect) -> Window? {
        let own = windows.filter { $0.pid == pid && $0.layer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
        if let windowFrame {
            let matching = own.filter { difference($0.frame, windowFrame) <= frameTolerance }
            return matching.count == 1 ? matching[0] : nil
        }
        let containing = own.filter { $0.frame.contains(CGPoint(x: field.midX, y: field.midY)) }
        return containing.count == 1 ? containing[0] : nil
    }

    /// The part of the window to keep, in points from its top left: from the top of the window to the bottom of the
    /// field, across the field's column widened to at least half the window. Nil when the field is not in the window.
    public static func region(window: CGRect, field: CGRect) -> CGRect? {
        guard window.intersects(field) else { return nil }
        let width = min(window.width, max(field.width * 1.3, window.width * 0.5))
        var column = CGRect(x: field.midX - width / 2, y: window.minY, width: width, height: field.maxY - window.minY)
        column.origin.x += max(0, window.minX - column.minX) - max(0, column.maxX - window.maxX)
        let region = column.intersection(window)
        guard !region.isNull, region.width >= 16, region.height >= 16 else { return nil }
        return region.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// Pixels to capture a window of `size` points at the display's scale, with the longer side at most `maximumSide`.
    public static func pixelSize(of size: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        let full = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(1, CGFloat(maximumSide) / max(full.width, full.height))
        let width = Int((full.width * factor).rounded()), height = Int((full.height * factor).rounded())
        return width > 0 && height > 0 ? (width: width, height: height) : nil
    }

    /// `region` in the pixels of an image of the whole window, whose top-left pixel is the window's top left. A
    /// single-window capture ignores a source rectangle, so the region is cut from the image afterwards.
    public static func pixelRegion(_ region: CGRect, window: CGSize, image: (width: Int, height: Int)) -> CGRect? {
        guard window.width > 0, window.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / window.width, scaleY = CGFloat(image.height) / window.height
        let pixels = CGRect(x: region.minX * scaleX, y: region.minY * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels.isNull || pixels.width < 1 || pixels.height < 1 ? nil : pixels
    }

    static func difference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }
}
