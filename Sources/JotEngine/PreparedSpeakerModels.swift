import FluidAudio

/// A fully prepared FluidAudio manager: models/configuration are read-only during
/// processing. SpeakerPass owns it and never calls prepareModels again; releasing
/// the owner during an await cannot change the retained manager used by that run.
final class PreparedSpeakerModels: @unchecked Sendable {
    let value: OfflineDiarizerManager
    init(manager: OfflineDiarizerManager) { value = manager }
}
