import CoreGraphics

/// Converts between the two screen coordinate systems on macOS.
public enum ScreenGeometry {
    /// Accessibility measures from the top-left of the primary display and AppKit from its bottom-left, so only y flips.
    /// Secondary displays keep their offsets: a display to the left stays at negative x, one above lands above the primary's height.
    public static func appKitRect(accessibilityOrigin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: accessibilityOrigin.x, y: primaryScreenHeight - accessibilityOrigin.y - size.height, width: size.width, height: size.height)
    }
}
