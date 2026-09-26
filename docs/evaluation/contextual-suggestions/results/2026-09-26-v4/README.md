# Draft prompt evaluation on the Mac

The normal and oracle-context runs evaluated the synthetic 18-scenario corpus on macOS from source revision `80842e24a4a000f7e180255f5cdc3b452bd49028`. Both used `jot-suggestion-v4`, the pinned AppleFM revision, greedy sampling and three iterations. All 54 records per mode completed and pass `check-suggestion-results.py`. The [normal](normal/results.jsonl) and [oracle](oracle/results.jsonl) directories preserve every raw output, prompt and run metadata. Human scores and scorer fields remain null.

Retrieval matched every authored source selection in normal mode. All 54 normal/oracle pairs have identical selected sources, prompt hashes, raw and processed outputs, and outcomes. Each mode produced 39 suggestions, 12 abstentions and three invalidations. Four older agent scenarios have outcome mismatches in every iteration: `agent-quoted-hostile-instruction`, `agent-same-length-edit-after-preview`, `agent-speakers-disagree` and `agent-unknown-preference`. Matching an expected outcome is not a quality score.

The new draft cases show material quality failures in both modes, repeated across all three iterations:

- `draft-seed-only-casual-reply` returns the rough notes verbatim rather than a message to Alex. The installed app's exact-echo review should withdraw that result, but this evaluation harness records the model output before that UI check.
- `draft-selection-inside-message` includes `Hi team` and `Thanks`, which are outside the selected replacement range. Accepting that text as the replacement would duplicate the surrounding message.
- `draft-agent-prompt-from-notes` changes the request into a first-person plan and drops the instruction not to touch the settings UI.
- `draft-missing-preference-not-invented` copies the surrounding dinner question rather than answering with the user's stated 7:30 preference.
- `draft-notes-ignore-unrelated-ambient` repeats the terse notes with little transformation. `draft-notes-without-intent` abstains as expected.

These are agent observations of the recorded outputs, not human rubric scores. The prompt and output checks need repair before the draft flow meets [issue #90](https://github.com/StoneHub/jot/issues/90)'s useful-output acceptance criteria. Live selected-range insertion and field tests remain separate.

Warm generation latency (nearest-rank p95): normal median 422.5 ms, p95 1026 ms (`n=50`); oracle median 417.5 ms, p95 1027 ms (`n=50`). Warm time to preview: normal median 519 ms, p95 1026 ms (`n=41`); oracle median 513 ms, p95 1027 ms (`n=41`). Each mode has one cold generation and preview sample: 965 ms normal, 821 ms oracle. Greedy repeats are not independent quality trials.
