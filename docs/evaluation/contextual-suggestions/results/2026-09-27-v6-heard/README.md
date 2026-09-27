# Heard-speech selection rewrite probe

The [synthetic two-case corpus](corpus.json) isolates the v6 draft prompt: one case includes a matched sentence Jot heard, and the other has the same selected notes without that source. It was run against Apple's on-device model on September 27, 2026, with greedy sampling and three iterations per case. The [raw results](results.jsonl), [prompts](prompts.jsonl), and [run metadata](run.json) are retained. `check-suggestion-results.py --corpus .../corpus.json` validates the six records structurally; the full-corpus fixture validator intentionally does not apply to this narrow subset.

| Case | Output in all three iterations | Assessment |
| --- | --- | --- |
| Matching heard sentence | “Shout out to Hank Green for pointing out that it's not really a paradox, it's a shitty name, but you get the idea.” | Restores the missing “pointing” and the quote's ending, keeping the user's framing. |
| Same notes, no heard sentence | “Shout out to Hank Green for out that it's not really a paradox, it's shitty name, but you you get” | Leaves the missing word and errors unchanged. |

The focused probe supports the specific quote-restoration behavior, not general draft quality. Repeated greedy outputs are not independent evidence, and the harness supplies the source directly; the `HeardSpeech.match` and coordinator tests separately cover retrieval, grouped-turn deduplication, bounds, and row revalidation. The v6 prompt changes only drafts with a `heard-speech` source; v5 continuation, reply, shell, and ordinary draft wording remains in place. Physical field selection, preview, and Tab insertion remain for Monroe's end-to-end use.
