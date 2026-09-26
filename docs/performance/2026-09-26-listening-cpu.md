# Listening CPU investigation — September 26, 2026

Second pass on #93, after [#105](https://github.com/StoneHub/jot/pull/105) stopped a quiet room from running the speaker model. The question here is why the installed app measured a 5% median with bursts to 30% while the pipeline harness accounts for about 2 CPU seconds per audio minute (3% of one core) with speech and 0.7% without.

## What the installed app could still say

`jot status` and `jot diagnostics` were read (read-only) from the installed 0.2.6 at 21:46 UTC. That process had been relaunched about 1.8 hours earlier and had never listened: models `not loaded`, two lifecycle events (launch, sleep at 111 s), zero recognition jobs, and 194 paused samples between 0.05% and 0.95% CPU (median 0.08%). Reports reset when Jot quits, so the 191-job buffer the issue quotes is gone. The split of Monroe's real jobs into speech, below-gate quiet and other no-speech could not be recovered; export `jot diagnostics` before the next relaunch when this recurs.

What the issue recorded still says something: 191 jobs, 75 `noSpeech`, so 116 (61%) produced text. Each ambient job is at most 3 seconds, so the buffer covered roughly 8 minutes with text arriving every 4 seconds. The 5% median and the 30% readings were taken during speech, not in a quiet room. In the harness, a conversation with 47% text jobs costs 1.9 CPU s per audio minute (3.2%) before #105; 61% text jobs extrapolates to about 4%.

## Bursts

A 30% one-second `ps` reading is 0.3 CPU seconds in that second. One recognition job with speech runs Parakeet on up to 7 seconds of window plus Sortformer on the new chunk; the harness measures a median 0.19 s of wall time per such job, and Core ML runs on several threads, so one job landing inside a one-second window reads as 20–40%. With text in 61% of jobs, one lands every 4 seconds. These bursts are recognition doing its job on speech, not quiet-time work. After #105 a quiet chunk costs about 5 ms of CPU in the real-time harness (0.42 CPU s per minute over 76 chunks).

## What the service does around recognition (measured)

`JotRecoveryChecks --listening-overhead` drives the real `SpeechService` on the wall clock with recognition stubbed to return at once, so it isolates the service's own listening work: the timer tick, the microphone drain, the once-a-second status work, saving a row, and how often the service tells every screen to redraw. Release build, fresh `CFFIXED_USER_HOME`, 40-second runs, A = `origin/main` (with #105), B = this change.

Once-a-second status work, CPU per call:

| Call | CPU |
| --- | ---: |
| `ResourceSampler.sample` (`proc_pid_rusage`) | 0.001 ms |
| `AXIsProcessTrusted` | 0.001 ms |
| `AVCaptureDevice.authorizationStatus` | 0.16 ms |
| `TranscriptCleanup.availability` (Foundation Models) | 0.14 ms |

Together about 0.3 ms per second, 0.03% of a core. The audio engine tap, format conversion and the screens are outside the tool.

Wall-clock runs, CPU seconds per minute and whole-window invalidations (`SpeechService.objectWillChange`), two runs each, interleaved A1 B1 A2 B2:

| Run (40 s) | A CPU s/min | A invalidations | B CPU s/min | B invalidations |
| --- | ---: | ---: | ---: | ---: |
| Digital silence, timer tick (drain + status work), 50 quiet chunks | 0.10 / 0.13 | 19 / 18 | 0.13 / 0.12 | 0 / 0 |
| Digital silence, drain only (no status work) | 0.05 / 0.07 | 0 / 0 | 0.09 / 0.06 | 0 / 0 |
| Steady tone above the gate, one saved row per 3-second block (13 rows, words and store writes) | 0.12 / 0.12 | 29 / 35 | 0.14 / 0.16 | 29 / 29 |

The service's own CPU is small in every run (0.1–0.3% of a core) and its spread between runs is as large as any difference between A and B; the tool measures the service, not the screens, so the change is not expected to show there. The finding is the invalidation count in silence. `queuedSeconds` was `@Published`. The timer tick drains the microphone first, which can cut a chunk, and then does its status work while that chunk is still in the queue, before the worker takes it. Whenever the status second landed on a chunk close, `queuedSeconds` went to 0.8 and, a second later, back to 0: two whole-window redraws. In quiet a chunk closes every 0.8 s and the status second is every fifth tick, so this happened about every 4 seconds: 18–19 invalidations in 40 s on A (9–10 coincidences), none on B. In the tone run the same coincidence adds the 6 extra invalidations of A2 (3-second chunks, so less often). Every other tick-time publication only assigns on change.

The screens' cost per whole-window redraw is not visible to the tool. The paused measurements in [2026-09-26-paused-cpu](2026-09-26-paused-cpu.md) put it at 11 ms (Live), 30 ms (Activity) and 55 ms (Tuning in the background, another app focused) of main-thread CPU each. At 0.48 per second that is 0.5–2.6% of a core in a quiet room, on top of the 0.7% the pipeline uses after #105, which is the largest remaining quiet-time cost this investigation found. Inferred from #97's numbers, not measured on the installed app.

With speech, each saved row sends `objectWillChange` twice (Live's append and the recent rows) in the same run-loop turn, which SwiftUI draws once; the tone run's count is two per row plus three from the first block's Dictations read, which the app does at launch instead. That redraw is needed: Live must show the row. Scoping it to Live rather than every service-observing view is a possible follow-up outside this change.

## The rest of the gap (inferred from code, not measured)

- **Audio engine.** `AVAudioEngine` runs the HAL I/O thread at the device's cycle (roughly 90 wakes per second) and the input tap converts each 4096-frame buffer to 16 kHz mono, about 12 times per second, then computes the RMS and copies the samples under a lock. Expected 0.3–0.6% of a core. Not measured: the check tool never starts a microphone, and a headless run would raise a microphone permission prompt.
- **Once-a-second screen work while listening.** The resource readout publishes to the sidebar meters (and the Activity grid when shown), and Live's header runs a one-second `TimelineView` for the elapsed-time chip. Both are small views; expected 0.1–0.2%.
- **Session audio file.** Each 0.2-second drain appends 12.8 KB on a utility queue when the speaker pass keeps audio. Small.
- **Event tap.** With dictation or suggestions on, every key event on the Mac passes through Jot's `CGEventTap` callback; negligible unless typing heavily during the measurement.
- **Measurement itself.** CPU seconds are not a fixed amount of work: at idle clocks and on efficiency cores the same work costs more of them. The pipeline harness measures the same quiet workload at 0.4 CPU s/min accelerated and 1.1 real time. `ps %cpu` is a decaying average, which spreads a 0.3-second job over neighbouring readings.

Adding the pieces: pipeline with speech (3–4%) + one needed redraw per row (0.3–1.4% at one row per 4 s) + audio engine (0.3–0.6%) + the spurious queued-audio redraws (0.2–2.6%, depending on how often chunks close: every 0.8 s in quiet, every 3 s or at each 0.7 s pause with speech) + meters and chip (0.1–0.2%) covers the 5% median. In a quiet room after #105 and this change the expected total is roughly 1–1.5%: pipeline 0.7%, audio engine, meters.

## Change

`queuedSeconds` is no longer `@Published`. The Activity grid reads it inside `ResourceReadoutView`, which already redraws once a second with the CPU readout, the same way `lagSeconds` and `lastInferenceSeconds` are shown; `jot status` computes its own queued figure. The `checkIdleRedraws` recovery check now drains through the timer tick with a fake microphone, as the app does, for five seconds of silence, so the status second lands on a chunk close at 3.2 s; it fails on `origin/main` with "Resource-only ticks told the whole window to redraw 2 times" and passes with this change.

## Manual Mac gates remaining

- Install and listen in a quiet room on the Live screen with cleanup off, keeping the same window and focus. Measure `ps -p <pid> -o time=` at two points 60 seconds apart and divide the difference by the elapsed time, as `scripts/check-paused-cpu.py` does for the paused state, once with #105 alone and once with this change. The expected difference is the spurious redraws, 0.5–2.5% depending on the screen shown.
- Check that the Activity screen's Queued audio figure still updates once a second while listening.
- If bursts are seen again, export `jot diagnostics` before relaunching so each job's `inferenceSeconds` and outcome are kept.

Raw outputs are under the session scratch area; no transcripts or private audio were involved, and the fixtures are digital silence and a constant tone.
