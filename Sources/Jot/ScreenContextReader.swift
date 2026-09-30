import AppKit
import ApplicationServices
import JotCore

/// Reads the visible text above a field in its window, for `ScreenContext`. Runs off the main thread: every call has
/// a short timeout, and the walk stops at an element and time budget. Children are visited last first, so the budget
/// goes to the newest content, nearest a chat composer. Other inputs and password fields are never read.
struct ScreenContextReader: @unchecked Sendable {
    struct Snapshot: Sendable {
        let items: [ScreenText]
        let field: CGRect
        let visible: CGRect
        let window: String?
    }

    let field: AXUIElement
    let fieldFrame: CGRect
    let parent: AXUIElement
    let window: AXUIElement?

    private static let elementLimit = 3000
    private static let budgetNanoseconds: UInt64 = 400_000_000
    private static let timeout: Float = 0.05

    func read() -> Snapshot? {
        let started = DispatchTime.now().uptimeNanoseconds
        // A browser's or Electron app's page is its web area; a native window is the fallback scope.
        var webArea: AXUIElement?
        var outermost: AXUIElement = parent
        var next: AXUIElement? = parent
        for _ in 0..<40 {
            guard let current = next else { break }
            AXUIElementSetMessagingTimeout(current, Self.timeout)
            let role = Self.string(current, kAXRoleAttribute)
            if role == "AXWebArea" { webArea = current; break }
            if role == kAXWindowRole { break }
            outermost = current
            next = Self.element(current, kAXParentAttribute)
        }
        let scope = webArea ?? window ?? outermost
        var visible = window.flatMap { Self.frame(of: $0) } ?? .infinite
        if let webArea, let area = Self.frame(of: webArea) { visible = visible.intersection(area) }
        guard !visible.isNull else { return nil }
        let column = fieldFrame.insetBy(dx: -fieldFrame.width * 0.15, dy: 0)
        let attributes = [kAXRoleAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var items: [ScreenText] = []
        var bytes = 0, visited = 0
        var stack: [(element: AXUIElement, depth: Int)] = [(scope, 0)]
        while visited < Self.elementLimit, bytes < ScreenContext.maximumBytes * 3,
              DispatchTime.now().uptimeNanoseconds - started < Self.budgetNanoseconds, let entry = stack.popLast() {
            visited += 1
            if CFEqual(entry.element, field) { continue }
            AXUIElementSetMessagingTimeout(entry.element, Self.timeout)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(entry.element, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 5 else { continue }
            let role = values[0] as? String
            let frame = Self.frame(position: values[2], size: values[3])
            // Skip what is at or below the field's top, scrolled out of view, or beside the field's column.
            if let frame, frame.width > 0, frame.height > 0,
               frame.minY >= fieldFrame.minY || !frame.intersects(visible) || frame.maxX < column.minX || frame.minX > column.maxX {
                continue
            }
            if role == kAXStaticTextRole {
                if let text = values[1] as? String, let frame, !text.isEmpty {
                    items.append(ScreenText(text, frame: frame)); bytes += text.utf8.count
                }
                continue
            }
            if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { continue }
            guard entry.depth < 80, let children = values[4] as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                stack.append((element: child as! AXUIElement, depth: entry.depth + 1))
            }
        }
        return Snapshot(items: items, field: fieldFrame, visible: visible, window: window.flatMap { Self.string($0, kAXTitleAttribute) })
    }

    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let items = value as? [AnyObject] else { return [] }
        return items.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// The static text inside a small element, such as a drawn field hint. Uses the caller's timeout on `element`.
    static func staticText(under element: AXUIElement) -> String {
        var parts: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 16 {
            let entry = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(entry.element, 0.005)
            if string(entry.element, kAXRoleAttribute) == kAXStaticTextRole, let text = string(entry.element, kAXValueAttribute) {
                parts.append(text); continue
            }
            if entry.depth < 3 { queue += children(of: entry.element).map { (element: $0, depth: entry.depth + 1) } }
        }
        return parts.joined(separator: " ")
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        return frame(position: position, size: size)
    }

    /// Uses the timeout already set on `element`.
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
