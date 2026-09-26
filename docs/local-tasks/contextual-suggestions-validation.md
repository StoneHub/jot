# Contextual suggestions: local acceptance status

PR [#89](https://github.com/StoneHub/jot/pull/89), issue [#88](https://github.com/StoneHub/jot/issues/88). Implementation revision: `4129375d744191a5e281ec23b24065ecf65b4946`. Later documentation commits do not change the app. The candidate is installed, but the PR remains a draft because live shortcut/card/insertion acceptance is unresolved. Canonical main remains `5c8e62f`.

## Verified

- 34 focused SuggestionEvaluation tests and all 221 Swift tests passed.
- 44 Python tests, corpus fixture validation, no-feedback checks and diff checks passed.
- `python3 scripts/local-pr-check.py 89 --current --filter SuggestionEvaluation` passed all gates, including signed Debug build and isolated recovery checks.
- Release build-only validation and capture-safe candidate installation passed. Built/installed executable SHA-256: `fa5871e7e8cef266cbc00a6209b240d1713f6142f01c71ed082e19e736858cee`. Installed path: `/Applications/Jot.app`; running executable verified inside that bundle.
- Installed settings render with the experimental notice, context explanation and shortcut control.
- Jot was stopped before installation and is now paused with models unloaded. Production transcript rows have identical before/after count and hash; suggestion preferences were restored exactly and no shortcut remains assigned.
- The test used a separate temporary home with one synthetic transcript. It did not insert test rows into production history. Its runtime is stopped. Temporary Control–Option–J was removed after the test; it is not a chosen default.
- The [v3 prompt comparison](../evaluation/contextual-suggestions/results/2026-09-25-v3/README.md) preserves both full modes; the rejected v2 outputs also remain recorded. Reply-quality failures persist.

## Unverified live acceptance

The Computer Use tool refused access to `com.openai.codex` for safety reasons. This restriction was respected. Native TextEdit accepted test keystrokes, but Jot’s global shortcut request counter stayed at zero on both attempts despite the enabled tap and configured binding. Thus those tool-generated keystrokes do not establish a physical global-shortcut test. No card or insertion was observed; there is no claim of successful real model generation in the installed app.

The following require live acceptance after a physical request can be made: blank Codex reply; exact Tab insertion with no send; typing/same-length edit/focus/source deletion/expiry withdrawal; Escape and modified/repeated Tab pass-through; secure-field rejection; IME composition; a request during dictation with capture continuity; window movement and a second display; unavailable-model notice. Pure snapshot/key/source/cancellation tests and existing capture/recovery checks passed, but do not replace these checks.

## Next decision and continuation

Monroe’s “is suggestion available, then request” wording may change the packet’s explicit-shortcut flow to an automatic availability check. A clarification is pending. No automatic behavior was added, no permanent shortcut chosen, and no message was sent to Jev.

Choose the trigger with Monroe, make a physical request using Settings → Tuning → Request a suggestion, complete the live checks, fix any findings, then merge under AGENTS.md, update canonical main and install/verify the merged build. Keep this issue open until those gates are resolved. Public distribution remains separate.
