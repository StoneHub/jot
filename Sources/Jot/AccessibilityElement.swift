import ApplicationServices

/// AXUIElement is a retained, immutable CF identity that may cross threads. Each
/// caller creates its own reference before configuring its messaging timeout;
/// this wrapper never changes that timeout or exposes mutable Swift state.
struct AccessibilityElement: @unchecked Sendable {
    let value: AXUIElement
}
