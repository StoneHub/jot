import AppKit
import ApplicationServices
import JotCore

/// The suggestion side of the captured field: reading it for a card, watching it while the card shows, selecting the
/// notes a draft replaces, and the frames that screen context and window images start from.
extension DictationInput {
    struct SuggestionField: Sendable {
        let draft: SuggestionDraftSnapshot
        let bundleID: String
        let appName: String
        let role: String
        /// The AX placeholder, or hint text a web editor draws inside the field.
        let placeholder: String?
        let generation: Int
        let keyRevision: Int
    }

    /// The captured field as it is now, or nil when its app is not in front, focus moved, or it cannot be read safely.
    func readSuggestionField() async -> SuggestionField? {
        let generation = targetGeneration
        let revision = suggestionKeyRevision
        guard let target, let reader = suggestionFieldReader(for: target) else { return nil }
        let readback = await Task.detached(priority: .userInitiated) { reader.read() }.value
        guard !Task.isCancelled, generation == targetGeneration, revision == suggestionKeyRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let readback else { return nil }
        drawnHint = (target.field, readback.value, readback.drawnHint)
        return suggestionField(from: readback, target: target)
    }

    /// The card's monitor: reads the captured field again off the main actor and returns where it is while it still holds
    /// the text, selection and hint the card was made from. Nil when focus, the field or its text changed, or the field
    /// reports no rectangle. Only the frontmost check and the comparison run on the main actor.
    func observeSuggestionField(_ expected: SuggestionField) async -> CGRect? {
        guard expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              let target, let reader = suggestionFieldReader(for: target) else { return nil }
        let pid = target.pid, field = target.field
        let readback = await Task.detached(priority: .userInitiated) { reader.read() }.value
        guard let readback, expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        drawnHint = (field, readback.value, readback.drawnHint)
        guard readback.draft == expected.draft, readback.role == expected.role, readback.placeholder == expected.placeholder,
              let frame = readback.frame else { return nil }
        return frame
    }

    private func suggestionFieldReader(for target: Target) -> SuggestionFieldReader? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid, let primary = NSScreen.screens.first else { return nil }
        return SuggestionFieldReader(pid: target.pid, field: target.field, knownHint: knownHint(for: target.field),
                                     primaryScreenHeight: primary.frame.height)
    }

    private func suggestionField(from readback: SuggestionFieldReadback, target: Target) -> SuggestionField? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), let bundle = app.bundleIdentifier else { return nil }
        return SuggestionField(draft: readback.draft, bundleID: bundle, appName: app.localizedName ?? bundle, role: readback.role,
                               placeholder: readback.placeholder, generation: targetGeneration, keyRevision: suggestionKeyRevision)
    }

    /// Draft acceptance: select exactly the notes the preview was made from, then insert over them through the
    /// verified path. Restores the selection and edits nothing when the field will not take that selection.
    func replace(_ seed: SuggestionSeed, with text: String, expected: SuggestionField) async throws -> DeliveryResult {
        let draft = expected.draft
        if seed.location == draft.location && seed.length == draft.length { return try await insert(text, expected: expected) }
        guard let target, await suggestionFieldIsCurrent(expected) else { throw InputError.targetChanged }
        guard let selected = SuggestionDraftSnapshot(value: draft.value, location: seed.location, length: seed.length),
              selected.selectedText == seed.text else { throw InputError.targetChanged }
        let rangeAttribute = kAXSelectedTextRangeAttribute as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target.field, rangeAttribute, &settable) == .success, settable.boolValue else {
            throw InputError.selectionUnavailable
        }
        func select(_ location: Int, _ length: Int) -> Bool {
            var range = CFRange(location: location, length: length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(target.field, rangeAttribute, value) == .success
        }
        let updated = SuggestionField(draft: selected, bundleID: expected.bundleID, appName: expected.appName, role: expected.role,
                                      placeholder: expected.placeholder, generation: expected.generation, keyRevision: expected.keyRevision)
        guard select(seed.location, seed.length) else { throw InputError.selectionUnavailable }
        try await Task.sleep(nanoseconds: 40_000_000)
        guard await suggestionFieldIsCurrent(updated) else {
            // Only put the caret back while the text is still the user's original draft.
            if expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
               await readSuggestionField()?.draft.value == draft.value, expected.generation == targetGeneration {
                _ = select(draft.location, draft.length)
            }
            throw InputError.selectionUnavailable
        }
        return try await insert(text, expected: updated)
    }

    /// Reads the text around the captured field later, off the main thread. Only the field's frame and window are read here.
    func screenContextReader() -> ScreenContextReader? {
        guard let target else { return nil }
        AXUIElementSetMessagingTimeout(target.field, 0.005)
        defer { AXUIElementSetMessagingTimeout(target.field, 0.005) }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, windowValue: CFTypeRef?, parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.field, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(target.field, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let frame = ScreenContextReader.frame(position: positionValue, size: sizeValue),
              AXUIElementCopyAttributeValue(target.field, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
        var window: AXUIElement?
        if AXUIElementCopyAttributeValue(target.field, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            window = (windowValue as! AXUIElement)
        }
        return ScreenContextReader(field: target.field, fieldFrame: frame, parent: parentValue as! AXUIElement, window: window)
    }

    /// Where the captured field and its window are, for a suggestion's window image. Only frames are read, each with a
    /// short timeout; the image itself is taken later, off the main actor.
    func windowImageCapture() -> WindowImageCapture? {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return nil }
        AXUIElementSetMessagingTimeout(target.field, 0.005)
        defer { AXUIElementSetMessagingTimeout(target.field, 0.005) }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?, windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.field, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(target.field, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let field = ScreenContextReader.frame(position: positionValue, size: sizeValue) else { return nil }
        var windowFrame: CGRect?
        if AXUIElementCopyAttributeValue(target.field, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            let window = windowValue as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.005)
            var windowPosition: CFTypeRef?, windowSize: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &windowPosition) == .success,
               AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &windowSize) == .success {
                windowFrame = ScreenContextReader.frame(position: windowPosition, size: windowSize)
            }
        }
        return WindowImageCapture(pid: target.pid, window: windowFrame, field: field)
    }

    func suggestionFieldIsCurrent(_ expected: SuggestionField) async -> Bool {
        guard expected.generation == targetGeneration, expected.keyRevision == suggestionKeyRevision,
              let current = await readSuggestionField() else { return false }
        return current.generation == expected.generation && current.bundleID == expected.bundleID
            && current.role == expected.role && current.draft == expected.draft && current.placeholder == expected.placeholder
    }

    private func knownHint(for field: AXUIElement) -> (value: String, hint: String?)? {
        guard let cached = drawnHint, CFEqual(cached.field, field) else { return nil }
        return (cached.value, cached.hint)
    }

    /// Hint text that a web editor draws inside the field and reports as its value, or nil when the value is the
    /// user's. Looks only a few levels into short values; see `FieldHint`. The field keeps its caller's timeout, which
    /// insertion relies on; descendants get a short one.
    nonisolated static func drawnHint(in field: AXUIElement, value: String) -> String? {
        guard (value as NSString).length <= 200 else { return nil }
        var hints: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(field, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 24 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if depth > 0 { AXUIElementSetMessagingTimeout(element, 0.005) }
            var classes: CFTypeRef?
            if depth > 0, AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes) == .success,
               let names = classes as? [String], FieldHint.isHintClass(names) {
                let text = ScreenContextReader.staticText(under: element)
                if !text.isEmpty { hints.append(text) } else if let own = stringAttribute(element, kAXValueAttribute) { hints.append(own) }
                continue
            }
            if depth < 3 { queue += ScreenContextReader.children(of: element).prefix(8).map { (element: $0, depth: depth + 1) } }
        }
        return FieldHint.valueIsHint(value, hints: hints) ? hints.joined(separator: " ") : nil
    }
}
