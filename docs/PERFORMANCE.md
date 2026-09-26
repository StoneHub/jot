# Local performance investigation

Activity keeps its existing interface. Performance investigation belongs in external reports, not new product dashboards.

Capture a report from the running app:

```sh
jot diagnostics > build/jot-performance.json
```

The command returns a JSON response with the report under `result`. The same report is available through the read-only `speech_diagnostics` MCP tool. A report is shared only when a caller reads or exports it; Jot makes no telemetry uploads.

The report contains the build configuration, startup/current/sample-peak physical footprint, resident memory, CPU percentage, buffered and queued audio duration, cumulative dropped audio, loaded-history counts, lifecycle state flags, typed lifecycle markers, and bounded per-job timing/outcome records. Times are relative to this process's launch. It excludes audio, transcript text, vocabulary, error messages, target-app names, session IDs, and filesystem paths.

Storage is in memory only: up to 2,880 samples at intervals of at least 30 seconds, 256 lifecycle events, and 200 job records. Continuous recognition and held dictation each keep at least 100 of them, so frequent recognition jobs do not push out recent dictations. Existing one-second resource readings update the current and sampled-peak values; no extra timer is installed. Reports reset when Jot quits. Export before an app update or restart when comparing runs. No continuous external collector is started automatically.

Per-job records measure continuous recognition: audio duration, queue wait, inference time when available, and outcome. Held dictation selects that same saved timeline rather than submitting a separate recognition job, and each released hold adds one `dictation` record: hold length (`audioSeconds`), release until recognition of the held range finished (`queueWaitSeconds`), cleanup time and outcome (`cleanupSeconds`, `cleanupOutcome`; absent when cleanup did not run), insertion time (`deliverySeconds`), and release until the text was in the field (`completionSeconds`). `dictationLatency` summarizes release-to-field time over inserted dictations, split into `dictationLatencyWithCleanup` and `dictationLatencyWithoutCleanup`; `dictationCleanupLatency` summarizes cleanup time wherever it ran. Failed and cancelled jobs remain visible and are excluded from latency summaries. Percentile values from a few jobs are not stable benchmarks.

`jot status` includes `dictationRecovery`: attempt state, pending work, and cleanup requested/completed/applied/bypassed counts with fallback reasons. Cleanup runs after raw recognition has been published and does not block the next audio job. A completed cleanup can legitimately leave text unchanged. Measure time waiting to collect audio separately from model inference; a fast model cannot compensate for a long capture chunk.

Compare the same build configuration, model/capture state, and UI state. Footprint is the primary memory-cost measure; resident memory also includes reclaimable pages. Neither headline value is a complete accelerator-memory inventory. Sampled peak can miss brief spikes. Keep a baseline before speech, then take reports after ordinary dictation and idle periods. A restart resets counters and therefore does not prove an optimization saved memory.

The next optimization candidates remain measurement-led: lazy preparation of the ambient speaker model and skipping unchanged history-document formatting. Neither change is included in this diagnostics implementation.

## Quiet listening CPU

`JotRecoveryChecks --quiet-cpu <speech files…>` runs the real models through the listening path the microphone uses (0.2-second drains, the capture RMS gate, bounded chunks, recognition, speaker attribution, a temporary store, cleanup off). It prints process CPU seconds per audio minute for a quiet room below the capture gate, fan noise above it, and a conversation built from the given files with faint speech and long pauses, followed by the conversation's saved rows and word speaker probabilities. Build the tool in Release with the same Xcode project (with `ENABLE_HARDENED_RUNTIME=NO`, so the ad hoc signed JotCore framework loads), run the baseline and the change on the same Mac, and diff the rows. `JOT_QUIET_CPU_REALTIME=1` paces audio on the wall clock; `JOT_QUIET_CPU_SECONDS`, `JOT_QUIET_CPU_GAP` and `JOT_QUIET_CPU_REPEATS` size the workloads. Use synthetic fixtures such as `say -o a.aiff "…"`, never private recordings.

`JotRecoveryChecks --listening-overhead` measures the rest of the service's listening work with recognition stubbed to return at once: the CPU of each once-a-second status call, then wall-clock runs of the real timer tick (a fake microphone owes 0.2 seconds per drain) in digital silence, with the drain alone, and with one saved row per block. Each run prints process CPU per minute, the recognition jobs and rows, the meter readouts, and how many times the service told every screen to redraw (`objectWillChange`). That count is the number to watch: a whole-window redraw costs the screens 10–55 ms of main-thread CPU in the paused measurements of [2026-09-26-paused-cpu](performance/2026-09-26-paused-cpu.md), which the tool cannot see. `JOT_OVERHEAD_SECONDS` sizes the runs. The microphone, the audio engine and the screens themselves are outside the tool; see [2026-09-26-listening-cpu](performance/2026-09-26-listening-cpu.md) for what they are expected to cost.
