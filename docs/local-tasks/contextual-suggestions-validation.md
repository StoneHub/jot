# Physical Fn regression: companion release events

The first double-Fn candidate failed with listening paused and active: physical taps were detected, but zero suggestion requests started. A bounded local gesture trace identified the cause: macOS emits key-down/key-up code 179 immediately after Fn release. The existing shortcut tracker treated it as unrelated typing and cleared the first short tap. The suggestion tracker also treated it as input, which could cancel a queued request after the second release.

Two tests replay the recorded, minimized sequence through the paused suggestion recognizer and listening/recovery recognizer, and verify that companion events cannot dismiss requesting/loading/ready cards. They failed before the fix (zero requests/recoveries and dismissed states). The fix passes Fn companion key pairs through to macOS without changing the tap, card or draft-revision state; actual typed input still dismisses. No timing thresholds or system keyboard settings change. Temporary gesture instrumentation has been removed from source.

Physical loop: `bash work/fn-hitl.sh` plus user presses, with metadata before/after. Both pre-fix runs returned `FAIL: physical double Fn did not start a suggestion request`. Automated regression command: `swift test --filter 'SuggestionEvaluationInteractionTests.testFn.*Companion'`. At `3ae2a33`, all 231 Swift tests (44 focused), 44 Python tests, portable checks, signed Debug build and isolated recovery checks passed. Signed Release build and capture-safe installation passed; built and installed executable SHA-256 `281f285b644ff7b1583e12c58c1d72e66ddbeb3aad77b9c8674cf1c820c2e9be` match. Jot is running from `/Applications/Jot.app` with automatic requests off and listening paused. Runtime status confirms the temporary diagnostic fields are absent. After the user resumed physical Fn testing, installed diagnostics reported four requests and a ready, visible card with zero insertions. This changes the original zero-request failure to a generated preview. Human card confirmation and Tab insertion are still pending; the full PR is not yet accepted.

---

# Request-only follow-up: September 26 live feedback

The user saw the automatic card, but it contained the composer placeholder and appeared too often. This confirms a visible preview, not useful output or Tab insertion. The request-only follow-up removes the automatic scheduling task and uses double-tap Fn. Holding Fn keeps dictation; disabling Suggestions restores the former double-tap recovery behavior. Fn suggestions also work when dictation is disabled or bound to another key. Busy/IME/unsafe fields still abstain.

The follow-up validates AX placeholder/count consistency and rejects exact placeholder/draft echoes. This is a defensive fix: the original Codex AX attributes could not be inspected, so its precise cause is not established. Chat history is not yet connected; see the [updated task scope](contextual-suggestions.md#updated-trigger-decision-september-26).

At implementation `e7ef52b`, 42 focused and all 229 Swift tests, 44 Python tests, fixture/no-feedback/diff checks, signed Debug build and isolated recovery checks passed. UI-help-only follow-up `0c6fe84` passed signed Release build-only validation. Release executable SHA-256: `bf6e015a2832a429ad02702eb224b220a362b1bf076c73675a1273ef604a6bef`. The user authorized pausing capture and installation. The checked candidate is installed and running from `/Applications/Jot.app`, with matching built/installed executable hashes. Installed Tuning shows Suggestions on and the double-Fn instructions. Diagnostics report `automatic: false`, `requests: 0`, `insertions: 0`, and `microphoneRunning: false`; listening remains paused. No physical gesture success is claimed. Physical double-Fn, hold-Fn, and Tab acceptance remain required. The PR remains draft for that gate.

---

# Automatic contextual suggestions: local acceptance status

PR [#89](https://github.com/StoneHub/jot/pull/89), issue [#88](https://github.com/StoneHub/jot/issues/88). Implementation revision: `b86adccf04a13c1c68dc248135b3d53d237688e6`. Later documentation commits do not change the app. This automatic candidate is installed and enabled. The PR remains a draft because physical Tab/card acceptance is still unverified; canonical main remains `5c8e62f`.

## Trigger decision resolved

Monroe clarified that Jot may suggest automatically: Tab accepts; typing dismisses the suggestion and keeps the user’s own input. No request shortcut is needed. The optional shortcut remains only for requesting again.

A read-only probe waits for a stable field/draft/context for 750 ms, with at least two seconds between automatic attempts. It does not take the target owned by dictation. New source revisions can offer a suggestion even in an unchanged draft. Empty results stay quiet; an unchanged dismissed/abstained draft and context are not retried, and a successful insertion does not trigger another completion of itself. Typing, focus changes, source changes and expiry still cancel; every insertion still needs Tab plus exact field/selection/source revalidation.

## Verified

- 37 focused SuggestionEvaluation tests and all 224 Swift tests passed.
- 44 Python tests, corpus fixture validation, no-feedback and diff checks passed.
- `python3 scripts/local-pr-check.py 89 --current --filter SuggestionEvaluation` passed all gates, including signed Debug build and isolated recovery checks.
- Release build-only validation and capture-safe candidate installation passed. Built/installed executable SHA-256: `f39b0dfbc6f8a1abb96bfd9c1051734eabacef79e02180956be98fab0ca7872c`. Installed/running executable: `/Applications/Jot.app/Contents/MacOS/Jot`.
- Installed settings show Automatic suggestions on, optional retry shortcut, and the Tab/typing/Escape explanation. No shortcut is assigned.
- During a separate-home test with one synthetic transcript, installed diagnostics reported `automatic: true`, `requests: 1`, `outcome: ready`, `visible: true`, `insertions: 0`. This establishes a generated automatic preview according to app metadata. It does not establish which physical field was targeted, visual card correctness, or Tab insertion: the UI tool’s separately controlled TextEdit window did not reflect subsequent requests, and its screenshot did not include the panel.
- The isolated runtime is stopped. Normal Jot is running, paused with models unloaded. Production transcript rows have identical before/after count and hash. No synthetic rows were added to production history.
- The [v3 prompt comparison](../evaluation/contextual-suggestions/results/2026-09-25-v3/README.md) and rejected v2 outputs remain recorded. The automatic-trigger change does not alter the prompt or corpus expectations; known reply-quality failures persist.

## Remaining live acceptance

Computer Use refuses access to `com.openai.codex` for safety reasons. The restriction was respected. Its application-targeted input has not established a physical global-key test. Automatic-generation metadata succeeds, but these still need live checks: the intended blank Codex composer and visible card/source line; exact Tab insertion with no send; typing/same-length edit/focus/source deletion/expiry withdrawal; Escape and modified/repeated Tab pass-through; secure fields and IME composition; request during dictation with capture continuity; window movement/second display; unavailable-model behavior. Automatic abstentions/unavailability stay quiet; explicit retry can display a notice.

Pure debounce/key/source/snapshot/cancellation tests and existing capture/recovery checks passed, but do not replace those interactions. Complete available live acceptance, fix findings, merge under AGENTS.md, update canonical main, and verify the merged installation. The worktree and branch are retained for this unfinished gate. Public distribution remains separate.
