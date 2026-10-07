# Plan

## Goal and current state

Say it once. Jot types it where you are and remembers who said it, all on your Mac.

Updated October 7, 2026. The [architecture review](reviews/2026-10-07-architecture.md) records the source evidence, remaining large files and performance risks. [AGENTS.md](../AGENTS.md) governs delivery and preservation; [SWARM.md](SWARM.md) governs claims and integration. GitHub issues hold the work; this page orders it. Unsupported database preservation (#205 via #211) and the bounded `jot listen` CLI (#192 via #212) have shipped; #193 adds its opt-in agent skill and matching instructions. Pending session-audio writes are bounded (#207 via #213).

The main architecture chain has shipped: direct owners, one continuous capture/recognition timeline, off-main store execution and keyboard classification, shared live settings, named production types, separated suggestion evaluation, and Swift 6 complete strict concurrency. Do not repeat that work because an old issue description still describes the previous implementation. #63, #65 and #128 need the remaining scope stated explicitly; physical acceptance is a test-when-you-sit-down list, not a merge gate.

## Next work, in order

| Priority | Work | Reason and boundary |
| --- | --- | --- |
| 1 | #198 MCP listener | #192 is shipped and unblocks this ready issue. Reuse the bounded listener over the saved feed; one response per command, no extra capture or recognition. |
| 2 | #208 incremental held recovery; #209 active-session summaries | Reduce work that grows with session/hold length. Core changes run one at a time; #207 audio-write bounds are shipped. |
| 3 | #194 wait for speech / end-of-speech signal | Reduce listener polling and command latency after the listener's semantics are stable. Use a cancellable bounded wait off the main actor. |
| 4 | #59 tuning lab | CLI first, real pipeline, reuse recognition for grouping/cleanup-only variants. Include very-short-tail accuracy checks: the operational 0.25-second test produced an unrelated phrase. This supplies evidence for subsequent model and speaker changes. |
| 5 | #150 short search terms; #39 field-aware dictation style; #37 live speaker naming | Bounded product features with focused acceptance. Live naming depends on measured speaker quality and the lab. |
| 6 | #38 meeting notes; #42 vocabulary suggestions | Preserve source facts and distinguish recognition, cleanup and generated output. |

Agent-listening parallel work: #196 opt-in prompt context can proceed independently; #195 first verifies the actual async hook wake behavior before implementation; #197 is a prototype and design choice, not authorization to ship a settings pane. #199 documentation/promotion follows #193 and recorded live acceptance evidence. #200 is the umbrella.

Suggestion work: #139 conversation association and #140 relevance ranking have implementations and synthetic coverage; their remaining tasks are realistic multi-session/quality/latency evidence and fixes found by use. #162 optional request-bound screenshots shipped off by default; permission/revocation, multiple displays and request-frequency energy still need user acceptance. #90 drafting is implemented but useful-output and native/browser behavior remain an ongoing quality task. #79 remains open for the Jot-managed Terminal bridge and broader acceptance; it is not an unimplemented suggestions engine.

Deferred: #40 calendar meeting names, then #33 microphone proximity. Public distribution is separate work under [RELEASING.md](RELEASING.md), not an automatic daily output.

## Refactor only the next responsibility being changed

`SpeechService`, `DictationInput`, `TranscriptStore` and `SuggestionCoordinator` remain large. Prefer coherent owners over moving arbitrary extensions to satisfy a line count:

- Extract database opening/schema/feed ownership when changing those contracts, keeping one serialized connection and atomic transactions.
- Separate focus/target lifecycle from delivery transactions when adding insertion behavior. Keep generation and cancellation checks together with the write they protect.
- Separate suggestion source preparation from receipt/card orchestration when adding context sources. Preserve request, field and source revision validation across every suspension.
- Move settings/status projection out of service lifecycle orchestration when changing those surfaces; avoid a new layer of forwarding protocols.

## Evidence and delivery

Judge Jot by release-to-field median/p95, transcript and speaker quality on known audio, no lost audio, and no main-thread stall over 50 ms while listening. Compare the same configuration, models and workload; export `jot diagnostics` before restarting. Static work-growth findings are not measured speedups.

A worker owns one ready issue and one worktree. Open one reviewed PR per issue. Integrate only after the trusted Mac `local-pr-check` passes on the current PR head with current main included. For pipeline changes also run generated or authorized local audio through the real-model recovery path. Install the checked Release build when capture is paused and work is idle; preserve transcript selection, history and preferences. Never rebuild/delete a database as a compatibility shortcut. Unsupported formats should be refused intact.
