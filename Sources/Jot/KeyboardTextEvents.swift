import CoreGraphics
import JotCore

/// Quartz events are prepared entirely on one worker and then frozen. No setter
/// is called after handoff; only the main actor posts the retained CF objects.
final class KeyboardTextEvents: @unchecked Sendable {
    private let events: [(CGEvent, CGEvent)]
    private init(events: [(CGEvent, CGEvent)]) { self.events = events }

    static func make(_ text: String, marker: Int64) throws -> KeyboardTextEvents {
        guard let source = CGEventSource(stateID: .privateState) else { throw ClipboardInsertion.Failure.directUnavailable }
        let events = try UnicodeTyping.chunks(text).map { chunk -> (CGEvent, CGEvent) in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ClipboardInsertion.Failure.directUnavailable
            }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            up.setIntegerValueField(.eventSourceUserData, value: marker)
            return (down, up)
        }
        return KeyboardTextEvents(events: events)
    }

    @MainActor
    func dispatch(validating: () throws -> Void) async throws {
        for (down, up) in events {
            await Task.yield()
            try validating()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
