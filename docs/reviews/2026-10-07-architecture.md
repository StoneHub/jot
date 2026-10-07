# Jot architecture and queue review — October 7, 2026

## Assessment

Jot has a sound small-app architecture with unusually useful recovery coverage. The remaining debt is concentrated orchestration and repeated storage work, rather than competing capture pipelines or a missing generic abstraction. A reviewer can follow the production owners and check failure behavior, but must still reason across several large stateful coordinators. A developer can add a read-only consumer or a context source without owning the microphone; changing delivery or lifecycle behavior requires more care.

Baseline: main `03d0c11ce1d876c1b2613989a4f3c19614c7780f` passed all four Mac checker gates on this date: portable checks, 380 package tests, signed Debug app build and isolated synthetic recovery. The installed app was initially paused/idle. Its exported diagnostic sample showed 0.13% CPU, 140 MiB physical footprint and zero dropped/queued audio. That is one idle snapshot, not a listening benchmark or an optimization claim. Raw reports and any live audio/transcripts remain local.

## Capture and recognition ownership

[MicrophoneCapture](../../Sources/Jot/MicrophoneCapture.swift) owns one AVAudioEngine input tap and conversion to mono 16 kHz floats. [CaptureController](../../Sources/Jot/CaptureController.swift) manages device selection and start/retry. [ListeningTimeline](../../Sources/Jot/ListeningTimeline.swift) assigns session time, assembles chunks and hands them to [Transcriber](../../Sources/Jot/Transcriber.swift), which admits one recognition job at a time into the [SpeechPipeline](../../Sources/Jot/SpeechPipeline.swift) actor. The microphone interface and injected dependencies let recovery checks exercise this flow without opening the real microphone.

[DictationCoordinator](../../Sources/Jot/DictationCoordinator.swift) marks a range in that same timeline and reads its persisted timed words after recognition catches up. It does not create a second recording or independent ASR pipeline; hold boundaries can flush the shared pipeline. Suggestions consume text/source snapshots only when requested. The CLI and MCP consume the same socket/store, rather than listening independently.

Some repeated work is intentional:

- [RecognitionCommitWindow](../../Sources/Jot/RecognitionCommitWindow.swift) retains two seconds of committed left context and two seconds of uncommitted tail. With the next three-second chunk, recognition can process seven seconds. Ownership by word timing and overlap suppression prevent re-appending the already committed words. This is one serialized recognizer, not literally one model evaluation per sample.
- The live speaker model provides provisional attribution; a later offline speaker pass improves identity/segments. The offline pass does not transcribe the audio again.
- Ambient phrase cleanup and dictation cleanup serve different outputs and can touch overlapping text. Do not remove one without preserving its output semantics and measuring the workload.

## Input contracts and feature seams

| Input | Current boundary | How to extend it |
| --- | --- | --- |
| Microphone audio | `MicrophoneSource` → capture/timeline → `AudioJob` → serialized pipeline | Keep a single clock and explicit gaps; the tuning lab should feed the real pipeline rather than create a parallel implementation. |
| Saved speech | `TranscriptStore` rows/timed words → changes/snapshots | Cursor, generation, deletion and replacement semantics belong to the shared feed. PR #203 now provides deletion/replacement/generation semantics for faithful followers. |
| Agent messages | `AgentHook` / `AgentContext` → bounded typed `SuggestionSource` values | Carry role, origin, conversation and revision. Select only an unambiguous visible conversation, not just the latest app's traffic. |
| Focused field / visible window | `SuggestionFieldReader`, `ScreenContextReader`, optional `WindowImageCapture` | Bind data to the target/request; invalidate after edits/focus changes. Images stay request-local. |
| Consumer APIs | `JotCLI` / MCP catalog → local socket → `SpeechServiceIPC` | Add pure folding/filtering types for consumers; avoid another capture, model instance or generic event bus. |

These are appropriate boundaries for current features. The protocol boundary is less strongly typed than the in-process pipeline: socket methods/JSON and some source kinds are strings, so catalog/decoder tests remain important. A universal input-stream framework would add indirection without solving the known defects. PR #203 completed the change feed (#122). The next consumer capabilities are wake filtering (#192) and a bounded cancellable wait with speech timing (#194).

## Quality through a reviewer's eyes

Strengths: Swift 6 with complete strict concurrency and warnings treated as errors; explicit actors/worker queues; generation and focus checks after suspension; saved dictation attempts survive delivery failure; bounded capture/inference queues; additive change-feed changes; synthetic recovery checks for lifecycle and persistence races; corpus parity coverage; privacy-conscious local diagnostics. Package tests do not compile the whole app, which is why the signed app and recovery targets remain separate gates.

Risks: `@unchecked Sendable` owners depend on lock/queue discipline; large coordinators mix wiring, projections, state and effects; some file comments describe the older incremental path rather than today's asynchronous commit path; stateful callbacks require readers to follow lifetime and cancellation ownership. Manual cross-app keyboard, field and model-output acceptance cannot be inferred from compiler success.

The serious persistence defect found in this audit is automatic deletion of unsupported older schemas. #205 implements a fix using a read-only compatibility refusal before a mutable SQLite connection changes journal state. Supporting formats 7/8 and adding feed metadata need no history reset.

## Large files

Production baseline line counts before this batch (line count measures navigation cost, not correctness):

| File | Lines | Responsibilities worth separating |
| --- | ---: | --- |
| `SpeechService.swift` | 1,169 | Dependency wiring, settings/status projections, lifecycle, timers, input changes, update coordination |
| `DictationInput.swift` | 898 | Tap coordination, target/focus lifecycle, AX insertion/readback, clipboard fallback, suggestion field handling |
| `TranscriptStore.swift` | 835 | Opening/schema, change feed, transcripts/words, attempts, recovery queries, session/label edits, deletion |
| `SuggestionCoordinator.swift` | 633 | Context preparation, generation, receipts, card state, monitoring and acceptance |
| `SessionLibrary.swift` | 511 | Async snapshots, incremental folds, view-facing state, edits and relabel coordination |
| `SetupView.swift` | 510 | Setup presentation and controls; lower priority than runtime owners |

The earlier one-type-per-file work largely shipped; creating dozens more files is not the goal. Split an independently owned responsibility while changing it, keep transaction boundaries intact, and avoid hiding a shared mutable state machine across extension files. #65 remains the readability/concept cleanup umbrella.

## Avoidable work and bounds

These are source-backed risks requiring measurements, not claimed observed slowdowns:

1. **Pending audio writes (#207):** `SessionAudioFile.append` queues closures retaining packets without admission accounting. Its two-hour file cap is checked later in the writer and does not bound pending memory. Bound pending work and make unavailable/truncated audio explicit so the speaker pass cannot use a discontinuous timeline.
2. **Long held dictation (#208):** `updateAttemptText` calls `recoveryText` across the entire hold for every recognized block, then rebuilds/upserts the full text. The recovery query also reads evidence/words per candidate row. Measure and incrementally update or coalesce without weakening crash recovery and cancellation.
3. **Long active sessions (#209):** `LibraryRows.addCommitted` calls the full `sessionSummary` aggregate each block. That rescans the growing session. The older `add` path is incremental but cannot simply replace it: asynchronous snapshots may already include the same rows. Preserve identity/revision correctness while bounding new-block work.
4. **Model lifecycle:** offline speaker models prepare with live models even when no pass is needed yet. Lazy preparation is a candidate after measuring startup latency and memory against first-pass cost.

Do not optimize away safety checks merely because they repeat. Suggestion freshness monitoring and insertion readback prevent stale writes; the important bounds are how much they read and whether that work is off the main actor.

## Queue interpretation and remaining acceptance

The initial inventory contained 27 open issues (including swarm control #201 and umbrella #200) and two draft PRs. The detailed next order lives in [PLAN.md](../PLAN.md).

- #63's store/tap off-main implementation and #128's evaluation separation shipped through #167/#189. Remaining physical acceptance belongs in short explicit lists, not descriptions claiming all store calls still run on main.
- #65's Swift 6 and named-type work shipped. Broader dense-statement/readability cleanup remains.
- #139 conversation selection and #140 relevance ranking are implemented with tests. Real multi-session selection and latency/quality evidence remain; weak lexical matching is intentionally conservative, not proof of semantic understanding.
- #162's optional screenshot context shipped disabled by default. Cross-display permission/focus/energy acceptance remains.
- #90 drafting exists; output quality and native/browser behavior still need use-driven improvements. #79 additionally owes the managed Terminal bridge.
- #59, #39, #37, #38 and #42 are substantive future work. #40 and #33 are deferred.

Test when sitting down: physical hold/release and double-Fn/Tab in native/Electron/browser fields; cancellation while focus/text changes; two agent conversations plus an unrelated chat field; screenshot permission enable/revoke and multiple displays; a long meeting/hold; natural wake commands amid ambient talk. Record failures and fix forward. These are not assertions that every scenario was exercised by the automated checks.
