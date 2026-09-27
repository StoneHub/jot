# Plan

## Goal

Say it once. Jot types it where you are and remembers who said it, all on your Mac.

Jot is judged by three numbers:

- **Dictation latency:** key release to text in the field, median and p95.
- **Transcript quality on real multi-speaker audio:** word errors, speaker-turn errors, and how much cleanup helps.
- **Nothing dropped, nothing frozen:** zero audio gaps and no main-thread stall over 50 ms while listening.

## How we build

1. **Measure, then tune.** A quality or speed question is answered by a number from the tuning lab or `jot diagnostics`, not by feel.
2. **Recorded conversations are the test set.** Debates with two to four known speakers, crosstalk, and applause run through the real pipeline. Audio stays outside the repository.
3. **Settings are live, saved, and yours.** A change applies right away. Only values you change are saved, and they survive restarts, reboots, and updates. A new default reaches everyone who has not changed that setting. An update overrides a saved value only when it lists that setting on purpose.
4. **Fail fast, no history.** Main is the current state; git and the issue tracker are the only history. No migrations, legacy names, or compatibility aliases. When the database format changes, the database is rebuilt and old sessions are deleted. Settings are the one thing that carries over.
5. **The main thread is for the UI.** Nothing that grows with your data or waits on another app runs there.
6. **Readable over clever.** One type per file, named after the type. One word per concept across code, UI, and the socket API. One statement per line. Code calls the real object, not a protocol with one conformer.
7. **Ship daily.** Merge to main, install, and cut a pre-release at the end of the day. Each PR carries its own verification.

## Phases

### 0. Stop the freezes and the data loss

- [#54](https://github.com/StoneHub/jot/issues/54) Convert spoken symbols only in dictation, and compile the patterns once
- [#55](https://github.com/StoneHub/jot/issues/55) Keep cleaned text through the speaker pass and Regroup, and run both off the main thread
- [#56](https://github.com/StoneHub/jot/issues/56) Read the Live session in one query and add new rows without re-reading
- [#57](https://github.com/StoneHub/jot/issues/57) Fix the CPU readout and stop re-rendering the window for meters nobody sees
- [#71](https://github.com/StoneHub/jot/issues/71) Stop re-reading recent rows and the session list on every recognition block
- [#75](https://github.com/StoneHub/jot/issues/75) Read the speaker pass segments after Regroup waits, so the pass cannot be overwritten

### 1. Settings and the tuning lab

- [#58](https://github.com/StoneHub/jot/issues/58) One settings model that saves only what you change and applies live
- [#59](https://github.com/StoneHub/jot/issues/59) A tuning lab that runs recorded audio through the real pipeline
- [#60](https://github.com/StoneHub/jot/issues/60) Dictation latency and cleanup time in diagnostics
- [#72](https://github.com/StoneHub/jot/issues/72) Make jot diagnostics CPU samples cover the whole interval
- [#73](https://github.com/StoneHub/jot/issues/73) Use the tuned paragraph pause in Markdown exports

### 2. An architecture you can follow

- [#61](https://github.com/StoneHub/jot/issues/61) Replace the Host protocols and forwarders with direct references
- [#62](https://github.com/StoneHub/jot/issues/62) Move the recognition worker into Transcriber and fold listening state into one enum
- [#63](https://github.com/StoneHub/jot/issues/63) Take the store and the dictation shortcut off the main thread
- [#64](https://github.com/StoneHub/jot/issues/64) Delete legacy code and rebuild the database on format changes
- [#65](https://github.com/StoneHub/jot/issues/65) One type per file, one word per concept, and Swift 6 strict concurrency

### 3. Features

Monroe's decisions of September 27, 2026 set the order: finish the refactor chain first (#61, #62, #58, #63, #65, one at a time), then build the tuning lab, then the features it helps tune. Each issue carries its decisions in a comment.

| Order | Issue | Decided | Depends on |
| --- | --- | --- | --- |
| 1 | [#59](https://github.com/StoneHub/jot/issues/59) Tuning lab | Build it, CLI first | #58 |
| 2 | [#39](https://github.com/StoneHub/jot/issues/39) Dictation style per app | The field's role beats the app; built-in rules plus a short override list in General | #58, #60 |
| 3 | [#37](https://github.com/StoneHub/jot/issues/37) Name speakers in Live | Pass every ~30 s; remembered voices named automatically; names follow the voice; the final pass still runs | #55, #59 |
| 4 | [#38](https://github.com/StoneHub/jot/issues/38) Meeting notes | Top of the Markdown at End meeting; summary, decisions, action items with who, open questions; named meetings only | #59 |
| 5 | [#42](https://github.com/StoneHub/jot/issues/42) Vocabulary suggestions | Learn from cleanup changes only, not edits after insertion | #55 |
| Deferred | [#40](https://github.com/StoneHub/jot/issues/40) Meeting names from the calendar | Not now; when built, auto-name only when a remembered voice matches an attendee | #37 |
| Parked | [#33](https://github.com/StoneHub/jot/issues/33) Microphone proximity | Low-priority idea; no work until the rest ships | #59 |

## Contextual suggestions and managed integrations

The agreed direction is [contextual suggestions in Jot](CONTEXTUAL-SUGGESTIONS.md): one local engine uses relevant transcripts, meetings, summaries and contributed agent context across input surfaces, including blank fields. Codex is the first and primary use case; browser/native fields are part of the design. Move Terminal completion ownership, setup and updates into Jot while retaining a thin shell bridge for native buffer and Tab behavior.

The first slice shipped in #89 and #91: double-tap Fn requests a suggestion or a draft from notes in the field, Tab accepts, and the setting is on by default. Suggestion quality is not yet acceptable, and the Terminal bridge is not built; #79 and #90 track the rest. Its delivery sequence and acceptance scenarios preserve the capture, history and responsiveness work above.

## Architecture target

```
JotApp ── views observe the object they show
   │
SpeechService: listening state machine and wiring
   ├─ CaptureController ─ MicrophoneCapture (audio thread)
   ├─ ListeningTimeline: session, chunks, session audio
   ├─ Transcriber: chunk → recognition → rows (SpeechPipeline actor)
   ├─ LiveCleanup: Apple on-device model
   ├─ SpeakerRecognizer: speaker pass (SpeakerPass actor), People
   ├─ DictationCoordinator ─ DictationInput (tap on its own thread)
   ├─ SessionLibrary: what the screens read
   └─ JotSettings: live values, saved overrides
TranscriptStore: SQLite, called off the main thread
JotCLI / MCP ─ socket ─ SpeechServiceIPC
```
