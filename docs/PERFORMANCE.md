# Local performance investigation

Activity keeps its existing interface. Performance investigation belongs in external reports, not new product dashboards.

Capture a report from the running app:

```sh
jot diagnostics > build/jot-performance.json
```

The command returns a JSON response with the report under `result`. The same report is available through the read-only `speech_diagnostics` MCP tool. A report is shared only when a caller reads or exports it; Jot makes no telemetry uploads.

The report contains the build configuration, startup/current/sample-peak physical footprint, resident memory, CPU percentage, buffered and queued audio duration, cumulative dropped audio, loaded-history counts, lifecycle state flags, typed lifecycle markers, and bounded per-job timing/outcome records. Times are relative to this process's launch. It excludes audio, transcript text, vocabulary, error messages, target-app names, session IDs, and filesystem paths.

Storage is in memory only: up to 2,880 samples at intervals of at least 30 seconds, 256 lifecycle events, and the last 200 processed jobs. Existing one-second resource readings update the current and sampled-peak values; no extra timer is installed. Reports reset when Jot quits. Export before an app update or restart when comparing runs. No continuous external collector is started automatically.

Dictation completion time runs from job submission after Fn release to completion of processing and attempted insertion. Per-job records include audio duration, queue wait, inference time when available, and outcome. The latency summaries include completed, no-speech, and unverified-delivery jobs; failed and cancelled jobs are retained but excluded from summaries. Jobs cancelled before reaching the worker are represented by lifecycle events rather than fabricated timing records. Percentile values from a few jobs are not stable benchmarks.

Compare the same build configuration, model/capture state, and UI state. Footprint is the primary memory-cost measure; resident memory also includes reclaimable pages. Neither headline value is a complete accelerator-memory inventory. Sampled peak can miss brief spikes. Keep a baseline before speech, then take reports after ordinary dictation and idle periods. A restart resets counters and therefore does not prove an optimization saved memory.

The next optimization candidates remain measurement-led: lazy preparation of the ambient speaker model and skipping unchanged history-document formatting. Neither change is included in this diagnostics implementation.
