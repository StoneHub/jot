# Architecture

One SwiftUI menu-bar application owns the microphone and model lifecycle. A shared PorchCore module owns SQLite and the Unix socket protocol; the bundled `porch` helper provides CLI/MCP entry points. There is no web service.

AVAudioEngine → mono 16 kHz float samples → bounded capture queue → serialized speech worker → SQLite transcripts. Dictation gets queue priority and a focus-bound delivery ticket. Ambient and dictation can share capture; when both are enabled the same utterance can appear in both histories.

FluidAudio is pinned at `5c19d5e12320e22bbfb7a1877b089d2665a69add`. Parakeet v3 supplies text and word timing, Silero gates likely speech, and streaming Sortformer supplies four speaker probabilities. A single confident speaker is labeled speaker-1 through speaker-4. Multiple active speakers are marked overlap; insufficient evidence is unknown. Speaker state resets on session changes and audio discontinuities. Labels are scoped to sessions, with no biometric enrollment. Early streaming assignments are provisional in quality; this version does not revise persisted segments when later diarizer frames finalize.

## Bounds and lifecycle

- Callback-to-controller queue: 8 seconds of mono float audio.
- Dictation accumulation: 60 seconds; overflow cancels insertion.
- Ambient flush: nominally 10 seconds, or a quiet boundary after at least 2 seconds. A delayed controller tick can extend a block by up to the capture packet bound.
- Pending inference: at most three ambient jobs and one dictation job, plus one in-flight job. Excess ambient audio is dropped with an event. These are separate bounded buffers, not a claim that total audio residency is limited to 60 seconds.
- Sortformer timeline is bounded to 1,000 frames; local attribution probabilities are pruned.
- Pausing stops capture immediately and finishes queued ambient inference. Sleep, device change, input stalls, queue drops, and inference failures produce journal entries. Resume creates a new session. No automatic resume after sleep in this version.
- Quit stops the app and socket. In-flight/unflushed audio can be lost at quit; already committed transcripts remain.

## Delivery and access

Fn is observed by a listen-only event tap. It does not reconfigure macOS or suppress its existing shortcuts. A focus observer and application identity guard the captured field. AX insertion is preferred; the fallback restores the prior clipboard only if it has not been changed since staging. The app never submits the resulting text.

SQLite operations are serialized. The application-support directory is user-only and the socket is mode 0600; the server checks peer UID, bounds requests/responses, limits concurrent clients, and enforces input deadlines. A second service does not take over a live socket. No audio file is created by capture; diagnostics read an explicitly selected existing file.

No model inference sends microphone content to a remote provider. Model preparation downloads model artifacts; future agent reads are separate disclosure decisions. Third-party code and model terms remain their authors' terms: [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet v3 model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), and FluidAudio's referenced converted model repositories. This private implementation does not relicense those artifacts.
