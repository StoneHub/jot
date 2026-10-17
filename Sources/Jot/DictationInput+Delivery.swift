import AppKit
import ApplicationServices
import JotCore

/// Delivering text into the captured field: the accessibility write first, then typed or pasted text, each checked
/// against a fresh read of the field before and after.
extension DictationInput {
    private static let pasteEventMarker: Int64 = 0x50534F524348

    /// Never equates a successful AX call or dispatched shortcut with verified insertion.
    /// Field contents are used transiently for verification and never included in diagnostics.
    func insert(_ text: String, expected: SuggestionField? = nil) async throws -> DeliveryResult {
        // A quick recognition result can beat the asynchronous AX lookup. Wait only
        // for this press's bounded lookup, then keep the usual fail-closed behavior.
        if target == nil {
            for _ in 0..<14 where targetAcquisition != nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let target else { throw InputError.targetChanged }
        let generation = targetGeneration
        var path = "accessibility"
        defer { if targetGeneration == generation { clearTarget() } }
        do {
            try validateTransaction(target, generation: generation)
            guard !text.isEmpty else { return delivery(target, path: "none", outcome: "empty", verified: false) }
            if let expected, !(await suggestionFieldIsCurrent(expected)) { throw InputError.targetChanged }
            let before = await snapshot(target, forSuggestion: expected != nil)
            try validateTransaction(target, generation: generation)
            if let expected, !(await matches(before, expected: expected)) { throw InputError.targetChanged }
            try validateTransaction(target, generation: generation)
            var writable = DarwinBoolean(false)
            var accessibilityResult: AXError?
            let selectionAttribute = kAXSelectedTextAttribute as CFString
            if AXUIElementIsAttributeSettable(target.field, selectionAttribute, &writable) == .success,
               writable.boolValue {
                let result = AXUIElementSetAttributeValue(target.field, selectionAttribute, text as CFString)
                accessibilityResult = result
                // Electron may report AX success while ignoring the setter. Give its
                // accessibility tree a turn, then inspect what actually changed.
                try await Task.sleep(nanoseconds: 70_000_000)
                try validateTransaction(target, generation: generation)
                let after = await snapshot(target, forSuggestion: expected != nil)
                try validateTransaction(target, generation: generation)
                let readback = await compare(before, after, inserted: text, requireValue: expected != nil)
                try validateTransaction(target, generation: generation)
                if readback == .verified { return delivery(target, path: path, outcome: "verified", verified: true) }
                if !readback.allowsAccessibilityRetry(after: result) {
                    return delivery(target, path: path, outcome: "ambiguous_ax_write_no_retry", verified: false)
                }
            }
            path = "clipboard_hid"
            // Use a fresh snapshot; do not overwrite a user's edit made while AX settled.
            try validateTransaction(target, generation: generation)
            if let expected, !(await suggestionFieldIsCurrent(expected)) { throw InputError.targetChanged }
            let pasteBefore = await snapshot(target, forSuggestion: expected != nil)
            try validateTransaction(target, generation: generation)
            if let expected, !(await matches(pasteBefore, expected: expected)) { throw InputError.targetChanged }
            try validateTransaction(target, generation: generation)
            if let accessibilityResult {
                let readback = await compare(before, pasteBefore, inserted: text, requireValue: expected != nil)
                try validateTransaction(target, generation: generation)
                if readback == .verified { return delivery(target, path: "accessibility", outcome: "verified", verified: true) }
                if !readback.allowsAccessibilityRetry(after: accessibilityResult) {
                    return delivery(target, path: "accessibility", outcome: "ambiguous_ax_write_no_retry", verified: false)
                }
            }
            // Prefer direct text events. Clipboard fallback is safe only if no direct events were sent.
            path = try await ClipboardInsertion.deliver(paste: {
                path = "clipboard_hid"
                try validateTransaction(target, generation: generation)
                try paste(text, into: target)
            }, type: {
                path = "unicode_hid"
                try await typeUnicode(text, into: target, generation: generation)
            })
            for delay in [70_000_000, 130_000_000, 250_000_000, 300_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: delay)
                try validateTransaction(target, generation: generation)
                let after = await snapshot(target, forSuggestion: expected != nil)
                try validateTransaction(target, generation: generation)
                let readback = await compare(pasteBefore, after, inserted: text, requireValue: expected != nil)
                try validateTransaction(target, generation: generation)
                switch readback {
                case .verified: return delivery(target, path: path, outcome: "verified", verified: true)
                case .changed: return delivery(target, path: path, outcome: "changed_unverified_no_retry", verified: false)
                case .unchanged, .unknown: break
                }
            }
            return delivery(target, path: path, outcome: "dispatched_not_verified", verified: false)
        } catch {
            _ = delivery(target, path: path, outcome: "cancelled_or_failed", verified: false)
            throw error
        }
    }

    /// Copies field text off the main actor. Each worker configures a fresh AX
    /// reference, and the caller revalidates focus/generation before any write.
    private func snapshot(_ target: Target, forSuggestion: Bool = false) async -> FieldInsertionSnapshot {
        if forSuggestion {
            guard let draft = await readSuggestionField()?.draft else {
                return FieldInsertionSnapshot(value: nil, selection: nil)
            }
            return FieldInsertionSnapshot(value: draft.value, selection: NSRange(location: draft.location, length: draft.length))
        }
        let pid = target.pid
        let identity = AccessibilityElement(value: target.field)
        return await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.005)
            guard let field = Self.focusedField(application), CFEqual(field, identity.value) else {
                return FieldInsertionSnapshot(value: nil, selection: nil)
            }
            AXUIElementSetMessagingTimeout(field, 0.005)
            let selection = Self.selectedRange(of: field).map { NSRange(location: $0.location, length: $0.length) }
            return FieldInsertionSnapshot(value: Self.stringAttribute(field, kAXValueAttribute), selection: selection)
        }.value
    }

    private func matches(_ snapshot: FieldInsertionSnapshot, expected: SuggestionField) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            snapshot.value == expected.draft.value
                && snapshot.selection?.location == expected.draft.location
                && snapshot.selection?.length == expected.draft.length
        }.value
    }

    private func compare(_ before: FieldInsertionSnapshot, _ after: FieldInsertionSnapshot,
                         inserted text: String, requireValue: Bool) async -> FieldInsertionReadback {
        await Task.detached(priority: .userInitiated) {
            FieldInsertionReadback.compare(before, after, inserted: text, requireValue: requireValue)
        }.value
    }

    private func validateTransaction(_ target: Target, generation: Int) throws {
        try Task.checkCancellation()
        guard targetGeneration == generation else { throw InputError.targetChanged }
        try validateCurrent(target)
    }

    private func typeUnicode(_ text: String, into target: Target, generation: Int) async throws {
        let marker = Self.pasteEventMarker
        let events = try await Task.detached(priority: .userInitiated) {
            try KeyboardTextEvents.make(text, marker: marker)
        }.value
        try await events.dispatch { try self.validateTransaction(target, generation: generation) }
    }

    private func paste(_ text: String, into target: Target) throws {
        clipboardRestore?()
        clipboardRestore = nil
        pasteGeneration += 1
        let generation = pasteGeneration
        let clipboard = NSPasteboard.general
        let originalChangeCount = clipboard.changeCount
        let saved = try ClipboardInsertion.snapshot(clipboard)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw InputError.pasteUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventMarker)
        try validateCurrent(target)
        guard clipboard.changeCount == originalChangeCount else { throw ClipboardInsertion.Failure.unavailable }
        clipboard.clearContents()
        let wroteText = clipboard.setString(text, forType: .string)
        let ownedChangeCount = clipboard.changeCount
        let restore = {
            // Never overwrite something the user or another app copied after this paste.
            guard clipboard.changeCount == ownedChangeCount else { return }
            clipboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }
        guard wroteText else { restore(); throw ClipboardInsertion.Failure.unavailable }
        do { try validateCurrent(target) }
        catch { restore(); throw error }
        // Electron apps can ignore PID-directed keyboard events. Normal HID routing
        // reaches the currently focused editor, which was checked immediately above.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        clipboardRestore = restore
        // macOS has no paste-consumed acknowledgement. Allow the target to consume all
        // clipboard types before restoring, without blocking the microphone/UI thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            restore()
            if self?.pasteGeneration == generation { self?.clipboardRestore = nil }
        }
    }
}
