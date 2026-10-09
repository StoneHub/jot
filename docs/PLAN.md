# Plan

## Goal and current state

Say it once. Jot types it where you are and remembers who said it, all on your Mac.

Updated October 9, 2026. The order now puts speaker and recognition accuracy first; the tuning lab (#59 via #217) and the dropped-words fix (#215 via #216) have shipped. The [architecture review](reviews/2026-10-07-architecture.md) records the source evidence, remaining large files and performance risks. [AGENTS.md](../AGENTS.md) governs delivery and preservation; [SWARM.md](SWARM.md) governs claims and integration. GitHub issues hold the work; this page orders it. Unsupported database preservation (#205 via #211) and the bounded `jot listen` CLI (#192 via #212) have shipped; #193 adds its opt-in agent skill and matching instructions. Pending session-audio writes are bounded (#207 via #213).

The main architecture chain has shipped: direct owners, one continuous capture/recognition timeline, off-main store execution and keyboard classification, shared live settings, named production types, separated suggestion evaluation, and Swift 6 complete strict concurrency. Do not repeat that work because an old issue description still describes the previous implementation. #63, #65 and #128 need the remaining scope stated explicitly; physical acceptance is a test-when-you-sit-down list, not a merge gate.

## Next work, in order

| Priority | Work | Reason and boundary |
| --- | --- | --- |
| 1 | #218 speaker scoring in jot lab | The lab cannot score speakers yet, though the live speaker was right for about 73% of words on synthetic speech and the speaker pass for about 92%; this adds scoring only, and no speaker setting changes. |
| 2 | #219 recognition window-length experiment | 30 s windows kept 89% of words on the reverb and room fixtures, against 84–85% chunked, so this compares 3, 6, 10 and 15 s chunks and leaves the default to Monroe. |
| 3 | #220 JotEngine package target | The engine is reachable only through the app target, so this moves it into a `JotEngine` package target that `swift test` runs, with app and lab output unchanged. |
| 4 | #37 speaker pass during a session | Live speakers stay unnamed until the session ends, so this runs the speaker pass during the session, and its CPU cost must stay under a few percent. |
| 5 | #221 per-row speaker correction, with opt-in kept audio (30-day limit) | Nothing records which rows were wrong, so real audio cannot score speakers; this adds per-row corrections in Sessions, with tuning audio off by default and deleted within 30 days at most. |
| 6 | #222 accuracy gate (blocked by #218 and #220) | The four `local-pr-check` gates stayed green while #215 dropped words, so recognition and speaker PRs get a `jot lab` comparison against main that fails past a set tolerance. |
| 7 | Then the earlier ready work: #198 MCP listener; #208/#209 storage scaling; #194 wait for speech | These stay ready and rank below the list: #198 gives MCP clients the `jot listen` wait, #208/#209 bound work that grows with session length, and #194 cuts listener polling and command latency. |

Agent-listening parallel work: #196 opt-in prompt context can proceed independently; #195 first verifies the actual async hook wake behavior before implementation; #197 is a prototype and design choice, not authorization to ship a settings pane. #199 documentation/promotion follows #193 and recorded live acceptance evidence. #200 is the umbrella.

Suggestion work: #79, #90, #139, #140, #150 and #162 are parked for about a month; nothing is deleted. Status while parked: #139 conversation association and #140 relevance ranking have implementations and synthetic coverage; their remaining tasks are realistic multi-session/quality/latency evidence and fixes found by use. #162 optional request-bound screenshots shipped off by default; permission/revocation, multiple displays and request-frequency energy still need user acceptance. #90 drafting is implemented but useful-output and native/browser behavior remain an ongoing quality task. #79 remains open for the Jot-managed Terminal bridge and broader acceptance; it is not an unimplemented suggestions engine.

Deferred: #40 calendar meeting names, then #33 microphone proximity. Public distribution is separate work under [RELEASING.md](RELEASING.md), not an automatic daily output.

Releases go out weekly rather than per merge, until a second user exists.

## Refactor only the next responsibility being changed

`SpeechService`, `DictationInput`, `TranscriptStore` and `SuggestionCoordinator` remain large. Prefer coherent owners over moving arbitrary extensions to satisfy a line count:

- Extract database opening/schema/feed ownership when changing those contracts, keeping one serialized connection and atomic transactions.
- Separate focus/target lifecycle from delivery transactions when adding insertion behavior. Keep generation and cancellation checks together with the write they protect.
- Separate suggestion source preparation from receipt/card orchestration when adding context sources. Preserve request, field and source revision validation across every suspension.
- Move settings/status projection out of service lifecycle orchestration when changing those surfaces; avoid a new layer of forwarding protocols.

## Evidence and delivery

Judge Jot by release-to-field median/p95, transcript and speaker quality on known audio, no lost audio, and no main-thread stall over 50 ms while listening. Compare the same configuration, models and workload; export `jot diagnostics` before restarting. Static work-growth findings are not measured speedups.

A worker owns one ready issue and one worktree. Open one reviewed PR per issue. Integrate only after the trusted Mac `local-pr-check` passes on the current PR head with current main included. For pipeline changes also run generated or authorized local audio through the real-model recovery path. Install the checked Release build when capture is paused and work is idle; preserve transcript selection, history and preferences. Never rebuild/delete a database as a compatibility shortcut. Unsupported formats should be refused intact.
