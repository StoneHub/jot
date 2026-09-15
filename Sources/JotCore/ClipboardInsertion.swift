import AppKit

/// Clipboard preservation and the fallback decision shared by the actual dictation path and tests.
@MainActor
public enum ClipboardInsertion {
    public enum Failure: Error, LocalizedError {
        case unavailable, directUnavailable
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "The clipboard could not be preserved; no text was pasted."
            case .directUnavailable: return "Direct text insertion could not be started."
            }
        }
    }
    public static func snapshot(_ clipboard: NSPasteboard) throws -> [[NSPasteboard.PasteboardType: Data]] {
        try (clipboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw Failure.unavailable }
                values[type] = data
            }
            return values
        }
    }

    public static func deliver(paste: () throws -> Void, type: () throws -> Void) throws -> String {
        do { try type(); return "unicode_hid" }
        catch Failure.directUnavailable { try paste(); return "clipboard_hid" }
    }
}
