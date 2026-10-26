# Resource lifecycle audit — October 25, 2026

Scope: the Jot app, JotCore, the bundled Vorssaint helper and their relevant tests. Baseline: 0.3.6 / `16d9550`. Read-only Claude Haiku sweeps were reviewed against source by Claude Opus 5.5 at max effort and the implementation owner. Findings are scoped evidence, not a guarantee that every resource failure is covered.

## Changes

- Controller presence uses helper lifecycle hints, startup/wake/activation reconciliation and kernel exit observation. Hints never supply trusted state. Each candidate remains Jot’s sealed helper under a Vorssaint host. An exit stays authoritative while a stale process snapshot still lists that child. Observer cancellation restores standalone controls after the last helper ends without changing capture or the saved icon preference.
- WindowVisibility owns AppKit visibility observation for resource meters, Activity refreshes, setup download progress and the Live elapsed clock. Mounted but hidden/minimized content cannot keep periodic display work active. Multiple visible meters still share one sampler.
- Update-check and usage-report owners cancel their task and URL session on teardown. The updater also stops its schedule explicitly at application termination. Weak-owner loops exit when the owner disappears, with no strong reference held across the long sleep.
- AGENTS.md records the resource ownership, gating and teardown convention for future changes. No product explanatory copy was added.

## Retained recurring work

| Owner | Work and gating | Teardown / bound |
| --- | --- | --- |
| SpeechService | Audio drain while listening (0.2 s, adjusted by Low Power Mode); paused capabilities/diagnostics once per minute | Rescheduled on lifecycle changes; invalidated by shutdown |
| ResourceReadout | Jot-process CPU/memory once per second while actual meter windows are visible; one settling interval after a state change | One shared timer; stopped after the last visible reader/settling interval; separate diagnostics sampler |
| ActivityView / ActivityResourceTrends | Aggregate refresh every five minutes; trend snapshot every minute, only for a visible active Activity screen | SwiftUI task cancellation on visibility, activity, selection or view lifetime changes |
| LiveView | One-second elapsed label only while listening and visible | Clock subtree absent while hidden |
| SetupView | One-second cache-size read only while the download-progress step is visible and models are preparing | Visibility/model task cancellation; stale reads discarded |
| AppUpdater / UsageReporter | Infrequent scheduled update/opt-in usage work (six hours with tolerance) | Explicit cancellation and owner teardown; network requests retain existing timeouts |
| AudioInputDeviceWatcher | Core Audio device/default-input callbacks | Matching removal at capture shutdown |
| DictationInput | Keyboard/mouse/activation hooks while eligible | Paired disable/deinit cleanup; observation does not start capture |
| SuggestionCoordinator | Field follow while a preview is shown, every 250 ms | Thirty-second deadline, cancellation and focus/source validation |
| DictationHighlight / DictationSpeakerMute | Field-follow and mute-lease checks during an actual dictation operation | Explicit hide/end/release ownership; not paused idle loops |
| Capture retry / delivery verification / update handoff | Short waits inside an operation | Existing attempt/deadline bounds and cancellation |
| TranscriptWait | Requested IPC long poll, up to two waiters; half-second checks | At most 110 seconds per request; existing event-wait improvement belongs to #194 |

SQL row iteration, socket accept/receive blocking, and queue draining are not recurring idle timers. Do not replace clock-based sampling or bounded operation waits merely because their implementation contains a loop.

## Bounds and remaining work

The microphone queue remains bounded to eight seconds. Diagnostics retain at most 1440 samples, 256 events and 200 job reports. Speech models remain loaded on an ordinary Pause for immediate Resume and held dictation; Unload Models releases them. Speaker-pass models are released after their pass.

The audit found a final-chunk exception to the inference queue cap: a stalled recognizer needs a focused backpressure/recovery design that preserves audio. A separate measurement is needed for eager AXManualAccessibility activation in target apps before changing field acquisition. They are tracked in #357 (audio backlog) and #358 (target accessibility). Closed-menu redraw cost during listening is tracked as a measurement question in #359; no runtime cost was established by this source audit. These are not evidence of current paused inference or capture.

## Focused verification

Native controller checks cover idle silence beyond the former three-second interval; untrusted hints; startup discovery; multiple helpers; stale exited-child snapshots and ID reuse after reaping; explicit icon preference; observer teardown; and an actual abruptly terminated child process. Native window checks cover minimize/restore, panel open/close and meter removal. Release verification also retains the package tests, signed Release product checks, packaged ZIP digest, exact installed executable hash and capture-safe runtime verification.

Test when seated: toggle the Jot feature inside a running host, quit the host and reopen Jot. Standalone controls must remain reachable, saved preference must survive and capture must not start. Leave Activity or Live hidden/minimized and confirm it resumes current information when shown.
