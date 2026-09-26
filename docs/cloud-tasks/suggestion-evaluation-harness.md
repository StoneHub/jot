# Handoff: run the contextual-suggestion experiment

## Goal

Prepare a small, source-only Mac evaluation executable that turns the existing synthetic corpus into actual, attributable on-device results. This advances step 1 of #79; it does not install a suggestion feature.

## Current state

Resolve `cwd` with `git rev-parse --show-toplevel`; record branch, HEAD and `git status --short`. Start from current remote `main`, with PRs #83–85 merged (integration baseline `19b7f97`). The 12-scenario corpus and validator exist. Its authored expectations are test oracles, not measured model output. The Mac integration passed 187 Swift tests, 35 Python tests, signed build and recovery checks. No evaluation executable or product suggestion engine exists yet.

Cloud deliverable: an explicitly uncompiled source PR with portable checks; Mac compilation and tests are a hard acceptance gate. The current Swift package requires Apple frameworks, so Linux cannot compile the package or run the model. Do not install Swift to discover this again. Mac validation and actual evaluation belong to the local integrator.

## Required context and ownership

Read `AGENTS.md`, `docs/CLOUD-WORK.md`, `docs/CONTEXTUAL-SUGGESTIONS.md`, and `docs/evaluation/contextual-suggestions/README.md`. Inspect the corpus, validator, `Package.swift`, and `Sources/JotCore/TranscriptCleanup.swift` for the current AppleFM call pattern.

Own a new `Sources/JotSuggestionEvaluation/` executable, its focused tests/support, the minimal package product/target declaration, and evaluation docs. Keep app/capture/AX sources, the transcript database, shell configuration, dependency revisions and the fixture expectations unchanged. Do not build a plugin framework or general context database.

Jot pins AppleFM `737fac9e7147403f2777e0901f02452e8fc25ae7`, not the companion library's latest main. Inspect that revision's public source if needed. Reuse `AppleFMClient.modelAvailability` and its generic `generate` API; Jot owns prompt composition and deadline policy. Do not use the terminal/editor `complete` API for replies: it rejects blank input and has a different purpose. Do not bump the dependency to fix API uncertainty.

## Next steps

1. Run `python3 scripts/cloud-preflight.py` and the portable baseline once. Check this task's issue and open PRs. Stop on existing implementation overlap. Record environment limits once, then work from source.
2. Add `jot-suggestion-eval`, accepting an explicit corpus path and a new output directory. No connection to a running Jot or real transcripts. Create a typed input-only projection before selection or generation; keep the executable implementation in this one small target. Separate scenario input from oracle/ideal fields: normal retrieval and generation must not read expected selections, expected text or scoring answers. Keep an explicitly named oracle-context generation mode for isolating model behavior from retrieval, and label those results separately.
3. Implement the smallest deterministic, bounded source selector justified by the design: explicit scope/pins, source role/provenance, current revisions, exclusions and duplicates. Do not hard-code scenario IDs or invent semantic relevance from timestamps alone. Abstain where association is insufficient. Report selected and excluded source references with reasons. Keep retrieval evidence separate from model quality.
4. Use fresh AppleFM sessions with explicit user-draft instructions and mode-specific framing. Allow grounded empty-field requests. Apply the design's proposed six-excerpt/4 KiB input and 128-token limits, one outstanding request and a two-second deadline. Record unavailable/error/timeout honestly. Ensure cancellation cannot leak a request into the next scenario; if the framework cannot establish completion, stop the run instead of overlapping calls.
5. Emit structured JSONL records following the evaluation README: scenario/run/mode, selected source IDs, actual outcome/output, duration, prompt hash, corpus/source revision and available runtime/model metadata. Preserve actual output before presentation processing. Distinguish cold first request from subsequent warm requests; do not call every iteration cold or infer a model revision Apple does not expose. Human quality scores remain unscored until reviewed. No fabricated scores/results. Only synthetic evaluation outputs belong in these artifacts.
6. Cover decoding, oracle isolation, bounds, selection/exclusion, and simulated same-length input edits/source deletion before acceptance using an injected generator and focused tests. Mutate expected selections, ideal text and scoring answers and prove the normal selection, prompt and generated result do not change. Fake responses must be labeled test data. Do not insert into fields, execute shell commands, install hooks or resume capture. Document exact commands and the remaining Mac gate, then return one scoped PR and stop.

## Verification

Cloud: `python3 -m unittest discover -s scripts -p 'test_*.py'`, `python3 scripts/check-suggestion-fixtures.py`, `python3 scripts/check-no-feedback.py`, and `git diff --check`. Run only available checks; source review is not a Swift test pass. New result validation, if needed, should be stdlib-only and reject missing/invalid records without assigning semantic quality scores.

Required Mac gate after handoff: focused `swift test --filter SuggestionEvaluation`, full `swift test`, and `swift build --product jot-suggestion-eval`. Provide the executable's exact invocation for the committed corpus, with isolated output directories and normal versus oracle-context modes. The local integrator will run the actual model and review all outputs, including failures, before claiming quality or deciding the Codex vertical slice. No app installation is needed for this standalone experiment.

## Stop conditions

One task, one PR, no automatic subagents, timers, PR polling or repeated environment repairs. Five-minute preflight; at most one justified dependency/network correction. A prompt budget is not a spending cap. If the pinned API cannot express a required behavior, document the smallest unresolved contract rather than widening into an AppleFM redesign. Do not implement the Codex UI or Jot-managed Terminal migration in this packet.
