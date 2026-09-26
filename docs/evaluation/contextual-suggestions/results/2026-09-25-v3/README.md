# Prompt follow-up on the Mac

The shipped candidate is `jot-suggestion-v3`: v1 reply/continuation instructions with a narrower exact-command instruction. AppleFM remains pinned at `737fac9e7147403f2777e0901f02452e8fc25ae7`; generation now uses the pinned API’s `samplingMode: .greedy`. Corpus expectations are unchanged.

The broader v2 rewrite regressed replies: it fabricated a spaces preference and echoed the synthetic hostile instruction. Its complete [normal](../2026-09-25-v2/normal/results.jsonl) and [oracle](../2026-09-25-v2/oracle/results.jsonl) runs are preserved. It is rejected. Both modes produced 27 suggestions, 6 invalidations and 3 abstentions; these counts are not quality scores.

V3 preserves `make test-export` without adding the project name in all three iterations of both modes. Every other raw output equals the original final v1 run: invented `tabs`, assistant-question echoes, omitted scope constraints and empty drafts remain. The UI is experimental and proceeds at Monroe’s explicit request despite these known quality failures.

Both v3 modes completed 36 records: 24 suggestions, 9 abstentions and 3 invalidations, with no errors or timeouts. All normal source selections match the authored expectations; all 36 normal/oracle pairs have identical prompt hashes, source references, raw output, processed output and outcomes. Both directories pass `check-suggestion-results.py`. All human score and scorer fields remain null. This is agent inspection of actual outputs, not a human quality score.

- normal: warm generation median 406 ms, 32 calls. Source revision recorded verbatim in [run metadata](normal/run.json).
- oracle: warm generation median 408.5 ms, 32 calls. Source revision recorded verbatim in [run metadata](oracle/run.json).

Greedy repeats are not independent quality trials. These runs do not validate installed UI behavior, insertion, or capture performance. See the feature PR for those separate gates.
