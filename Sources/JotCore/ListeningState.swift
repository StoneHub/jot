import Foundation

/// Where listening stands. The service stores only its lifecycle, whether the microphone is on and whether a held dictation is running; `mode`, the model state and the screens' paused and ready checks all read this.
public enum ListeningState: Equatable, Sendable {
    /// Models are not loaded. Before the first Resume they have never been loaded.
    case paused(neverLoaded: Bool)
    /// Resume is loading models.
    case starting
    /// Models are loaded and the microphone is off.
    case ready
    /// The microphone is on and speech is being saved.
    case listening
    /// A held dictation is being captured while listening.
    case dictating
    /// Pause is unloading models.
    case unloading
    /// Resume could not load models.
    case failed

    /// The raw values are what `jot status` reports under "models".
    public enum Models: String, Sendable { case notLoaded = "not loaded", preparing, ready, failed, unloading, unloaded }

    /// `generation` is the lifecycle's: it stays 0 until the first Resume, so a paused service that never loaded reports "not loaded".
    public init(phase: ServiceLifecycle.Phase, generation: UInt64, microphoneOn: Bool, dictationActive: Bool) {
        switch phase {
        case .paused: self = .paused(neverLoaded: generation == 0)
        case .starting: self = .starting
        case .ready: self = dictationActive ? .dictating : (microphoneOn ? .listening : .ready)
        case .pausing: self = .unloading
        case .failed: self = .failed
        }
    }

    /// `jot status` reports this under "mode".
    public var mode: String {
        switch self {
        case .paused: "paused"
        case .starting: "starting"
        case .ready: "ready"
        case .listening: "ambient"
        case .dictating: "dictation"
        case .unloading: "pausing"
        case .failed: "failed"
        }
    }

    public var models: Models {
        switch self {
        case .paused(let neverLoaded): neverLoaded ? .notLoaded : .unloaded
        case .starting: .preparing
        case .ready, .listening, .dictating: .ready
        case .unloading: .unloading
        case .failed: .failed
        }
    }

    /// Models are loaded, whether or not the microphone is on.
    public var modelsLoaded: Bool { models == .ready }

    /// Paused, unloading, or failed to resume. A Pause still saving speech is not here: the service adds its pause request.
    public var isPaused: Bool {
        switch self {
        case .paused, .unloading, .failed: true
        default: false
        }
    }

    /// Resume or Pause is under way.
    public var isChanging: Bool { self == .starting || self == .unloading }

    /// The microphone is on, with or without a held dictation.
    public var isListening: Bool { self == .listening || self == .dictating }
}
