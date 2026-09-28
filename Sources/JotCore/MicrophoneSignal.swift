import Foundation

/// Measures input signal, not recognized speech. A quiet room with microphone noise must not trigger device hunting.
public struct MicrophoneSignal: Sendable {
    public private(set) var observedSeconds = 0.0
    public private(set) var silentSeconds = 0.0
    public private(set) var soundSeconds = 0.0
    public private(set) var level = 0
    public var isSilent: Bool { silentSeconds + 0.000001 >= 10 }
    public var heardSound: Bool { soundSeconds >= 0.1 }

    public init() {}

    public mutating func observe(samples: Int, rms: Float) {
        guard samples > 0 else { return }
        let seconds = Double(samples) / 16_000
        observedSeconds += seconds
        let amplitude = rms.isFinite ? max(0, Double(rms)) : 0
        // Near digital silence, far below the normal capture quiet boundary of 0.002.
        silentSeconds = amplitude < 0.00001 ? silentSeconds + seconds : 0
        if amplitude >= 0.0001 { soundSeconds += seconds }
        level = min(8, max(0, Int((sqrt(amplitude / 0.05) * 8).rounded())))
    }
}

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
