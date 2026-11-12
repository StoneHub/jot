import FluidAudio

/// Turns one window of 16 kHz mono audio into timed words. `SpeechPipeline` owns everything around it:
/// the speech gate, speaker attribution, and the commit window that decides which words are new.
/// An engine holds its own models, so loading and releasing them is its job too.
public protocol RecognitionEngine: Sendable {
    /// Downloads and loads the models. Loading an engine that is already loaded does nothing.
    func load() async throws
    /// Releases the models; `load()` brings them back.
    func unload() async
    /// Recognizes one bounded window of audio. Word times count from the first sample, so a word the engine hears
    /// in padding it added itself falls after the real audio.
    func recognize(_ samples: [Float]) async throws -> [WordTiming]
}
