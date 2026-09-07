# Architecture

One SwiftUI menu-bar application owns the microphone and model lifecycle. A shared JotCore module owns SQLite and the Unix socket protocol; the bundled `jot` helper provides CLI/MCP entry points. There is no web service.

AVAudioEngine → mono 16 kHz float samples → bounded capture queue → serialized speech worker → SQLite transcripts. Dictation gets queue priority and a focus-bound delivery ticket. Ambient and dictation can share capture; when both are enabled the same utterance can appear in both histories.

FluidAudio is pinned at `5c19d5e12320e22bbfb7a1877b089d2665a69add`. Parakeet v3 supplies text and word timing, Silero gates likely speech, and streaming Sortformer supplies four speaker probabilities. A single confident speaker is labeled speaker-1 through speaker-4. Multiple active speakers are marked overlap; insufficient evidence is unknown. Speaker state resets on session changes and audio discontinuities. Labels are scoped to sessions, with no biometric enrollment. Early streaming assignments are provisional in quality; this version does not revise persisted segments when later diarizer frames finalize.

## Bounds and lifecycle

Ambient speaker attribution uses user-adjustable confidence and minimum-turn duration. Short candidate changes and isolated hesitations retain the preceding confirmed speaker within each inference block; sustained changes create a new turn. This can also merge a genuine short reply. Paragraph pause controls both quiet-boundary flushing and turn grouping. History may combine nearby same-speaker rows and hide filler-only rows without changing stored source text. Settings persist locally and are exposed by status.

- Callback-to-controller queue: 8 seconds of mono float audio.
- Dictation accumulation: 60 seconds; overflow cancels insertion.
- Ambient flush: nominally 10 seconds, or a quiet boundary after at least 2 seconds. A delayed controller tick can extend a block by up to the capture packet bound.
- Pending inference: at most three ambient jobs and one dictation job, plus one in-flight job. Excess ambient audio is dropped with an event. These are separate bounded buffers, not a claim that total audio residency is limited to 60 seconds.
- Sortformer timeline is bounded to 1,000 frames; local attribution probabilities are pruned.
- Pause stops capture and Fn, discards pending buffers, cancels speech tasks, and invalidates their generation so late results cannot deliver. After active predictions/loads return, the pipeline releases ASR, VAD, diarizer, and timeline references. UI/CLI/MCP remain available; resource sampling slows to every five seconds. macOS may retain framework/allocator caches, so memory does not fall to zero. Resume reloads cached models and restores selected features. Sleep and device changes pause the whole service. Ambient-off alone finishes queued ambient inference while keeping Fn available.
- Quit stops the app and socket. In-flight/unflushed audio can be lost at quit; already committed transcripts remain.

## Delivery and access

Fn is observed by a listen-only event tap. It does not reconfigure macOS or suppress its existing shortcuts. A focus observer and application identity guard the captured field. AX insertion is preferred; the fallback restores the prior clipboard only if it has not been changed since staging. The app never submits the resulting text.

SQLite operations are serialized. The application-support directory is user-only and the socket is mode 0600; the server checks peer UID, bounds requests/responses, limits concurrent clients, and enforces input deadlines. A second service does not take over a live socket. No audio file is created by capture; diagnostics read an explicitly selected existing file.

No model inference sends microphone content to a remote provider. Model preparation downloads model artifacts; future agent reads are separate disclosure decisions. Third-party code and model terms remain their authors' terms: [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet v3 model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), and FluidAudio's referenced converted model repositories. This implementation does not relicense those artifacts.

The SwiftUI app uses a single `Window` scene, disables automatic tabbing, and switches activation policy between regular (Dock visible) and accessory (window closed). The menu-bar popover and window share the same service controls. Published model metadata is separate from installed-cache provenance.
