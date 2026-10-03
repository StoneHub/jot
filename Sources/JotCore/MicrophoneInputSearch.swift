import Foundation

/// Tries each alternative once, keeps the first with signal, and restores the original selection if none has signal.
public struct MicrophoneInputSearch: Sendable {
    private var original: String?
    private var tried = Set<String>()
    private var exhausted = false
    public var isSearching: Bool { original != nil }
    public init() {}

    public mutating func next(current: String, resolved: String?, candidates: [String], signal: MicrophoneSignal) -> String? {
        if isSearching {
            guard signal.observedSeconds >= 3 else { return nil }
            if signal.heardSound { self = Self(); return nil }
        } else {
            if signal.heardSound && !signal.isSilent { exhausted = false }
            guard signal.isSilent, !exhausted else { return nil }
            original = current
            if let resolved { tried.insert(resolved) }
            if !current.isEmpty { tried.insert(current) }
        }
        if let next = candidates.first(where: { !tried.contains($0) }) {
            tried.insert(next)
            return next
        }
        let restore = original
        original = nil; tried = []; exhausted = true
        return restore == current ? nil : restore
    }
}
