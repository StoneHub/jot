# Handoff: synthetic contextual-suggestion fixtures

## Goal

When assigned this task, build a small portable evaluation corpus and validator for the context-and-quality experiment in issue #79. Produce a reviewable PR, not a suggestion engine.

## Current state

Work from the runner's clone root (`git rev-parse --show-toplevel`), on its task branch. Read the live issue and record the checked-out commit. Preparation baseline: `47b757a`; the design is in `docs/CONTEXTUAL-SUGGESTIONS.md`. No production contextual-suggestion feature exists at that baseline. Earlier local model checks failed user/assistant perspective; empty-context abstention was host logic, not model success.

## Required context

Read `AGENTS.md`, `docs/CLOUD-WORK.md`, and the design's Outcome, Context, Request/acceptance, and Acceptance scenarios sections. This is a portable Python/JSON task with no runtime/model/network dependency beyond repository access. Proposed ownership: `docs/evaluation/contextual-suggestions/`, `scripts/check-suggestion-fixtures.py`, and a focused Python validator test file. Check whether those paths already exist before creating them. Keep app sources, Swift manifests and shell settings unchanged.

## Next steps

1. Run the portable preflight and baseline from `docs/CLOUD-WORK.md`; check the assigned issue and overlapping PRs. If this corpus already exists, report the overlap rather than creating a second one.
2. Define a versioned, minimal JSON format for 10–12 synthetic scenarios. Include target purpose/mode and input revision, source IDs/roles/scope/timestamps, expected included/excluded sources, expected suggest/abstain/invalidate result, and a short human scoring rubric. Include authored ideal text only when useful and label it as authored, never measured model output.
3. Cover matching versus unrelated project context, blank fields, unknown preference, explicit fix intent, wrong conversational role, multiple-speaker disagreement, deleted/stale sources, duplicate dictation/submitted prompt, quoted hostile instructions, and changed input revisions. Use synthetic names and paths only; no personal transcripts or API calls.
4. Implement a stdlib-only validator that checks schema/version, unique scenario/source IDs, reference integrity, allowed expected outcomes and required negative cases. Add focused tests proving malformed fixtures are rejected and the real corpus is accepted. Structural validation must not claim to grade semantic model quality.
5. Document one command for corpus validation and a separate future Mac experiment procedure. The procedure must record actual model/prompt/version, outputs, source selection, role/groundedness scores and latency without filling in invented results. Keep it short; defer app execution to the Mac integrator.
6. Run focused tests and portable checks; open a scoped PR linked to the assigned issue and parent #79. Report files, actual results and the pending on-device evaluation.

## Verification

Required new command: `python3 scripts/check-suggestion-fixtures.py` exits zero for the committed corpus and nonzero for invalid input. Run the focused stdlib `unittest` tests you add, existing portable checks and `git diff --check`. No Apple model score can be claimed from JSON validation.

## Risks and stop conditions

This task needs no Swift compiler, Xcode, captured audio, local Jot service or model credentials. Stop environment repair after the guide's bounded preflight. Do not implement runtime retrieval merely to demonstrate expected selections. One worker, no delegation or extra repo work. Completion means validated fixtures and a PR ready for local review; model usefulness remains a separate gate.
