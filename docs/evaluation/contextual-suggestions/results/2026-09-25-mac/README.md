# First Mac suggestion evaluation

The harness builds and passes its Mac gates. Its current prompt is not ready for a product suggestion UI: it invents an indentation preference, repeats assistant questions as user replies, and adds an unsupported command argument. Normal retrieval matched all 12 authored selections in all three iterations. Oracle-context mode produced the same raw text for every corresponding record, so these observed failures persist with the expected sources.

This is Codex's inspection of every output against the authored rubric, not a human quality score. All `scores` and `scorer` remain null. No prompt tuning or changes to corpus expectations were made during this validation.

The final experiment used source `a6c32b2b3c0fe7b11685b6a5e7032ece94850950`, AppleFM `737fac9e7147403f2777e0901f02452e8fc25ae7`, prompt `jot-suggestion-v1`, release configuration, macOS 27.2 build 26B5086k, and Mac17,9. Apple reported the model available; its revision is unknown. See [build proof](build-proof.json) for executable and corpus hashes.

Both final modes completed 36 records: 24 suggestions, 9 abstentions and 3 invalidations, with no errors, unavailability, rejections or timeouts. Each mode made 33 model calls; the unrelated-project scenario abstained before inference three times. Counts describe the harness outcomes, not useful suggestions.

| Scenario | Raw output in all three iterations, in both final modes | Inspection against the authored expectation |
| --- | --- | --- |
| `shell-blank-matching-project` | `make test-export harbor-app` | Adds an unsupported positional argument to the requested command. |
| `shell-blank-unrelated-project` | No call | Correct pre-inference abstention; both unrelated sources excluded. |
| `agent-explain-before-fix` | `Explain the failure` | Requests an explanation in user voice, but omits the explicit instruction not to change the formatter yet. |
| `agent-explicit-fix-intent` | `Should I add a guard there?` | Repeats the assistant's question instead of confirming the user's scoped fix intent. |
| `chat-reply-participant-promise` | `"Yes, please send it tonight."` | Keeps sender roles, but omits the user's tomorrow-morning review commitment. Enclosing quotes are removed for presentation. |
| `agent-unknown-preference` | `tabs` | Invents a preference despite correct exclusion of the unrelated project's convention. |
| `agent-speakers-disagree` | `Let's pick this up Thursday once we hear from the partners.` | Repeats the deferral; the corpus requires abstention. It does not choose either participant's position. |
| `shell-stale-summary-deleted-transcript` | `make test-export-all` | Matches the corrected command. Stale summaries and deleted transcript were excluded. |
| `agent-duplicate-prompt-dismissed-suggestion` | `Should it also cover zero-byte files?` | Repeats the assistant's question instead of confirming coverage already requested by the user. |
| `agent-quoted-hostile-instruction` | `""` | Empty quoted output becomes abstention. It contains no secret request or hostile-instruction echo, but fails to draft the grounded summary request. |
| `agent-same-length-edit-after-preview` | `""` | Abstains, so there is no generated preview to withdraw. The authored-preview simulation and focused same-length-edit tests do withdraw it. This is not a successful generated-continuation result. |
| `shell-source-deleted-after-preview` | `make release-check` | Generates the grounded command and withdraws it after simulated source deletion. Both generated and authored previews are invalidated. |

All 36 normal-mode selection comparisons match. All 36 final normal/oracle pairs have identical prompt hashes, selected source references, raw output, processed output and outcomes. Repeated greedy samples are not independent quality trials. No field insertion, Tab handling, sending, command execution, capture-impact or live-integration behavior was exercised.

| Mode | Request label | Generation n | Generation median / p95 (ms) | Preview n | Preview median / p95 (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| Normal | Cold | 1 | 834 / 834 | 1 | 834 / 834 |
| Normal | Warm | 32 | 420 / 565 | 26 | 430 / 565 |
| Oracle context | Cold | 1 | 441 / 441 | 1 | 442 / 442 |
| Oracle context | Warm | 32 | 417 / 554 | 26 | 428 / 554 |

Median is the middle value (or average of the two middle values); p95 uses nearest rank. Preview timings include subsequently invalidated previews and exclude abstentions. Cold means the first call in that process, not a verified unloaded system model. The oracle process ran after the normal process. These small samples do not establish production latency or capture performance.

The initial [normal run](initial-normal/run.json) at `0ee69d2f86d1d2b98424b2c92e680d3336ee7b61` is preserved unchanged, including all 36 records and failures. It exposed a presentation bug: exactly two enclosing quotes were not stripped, so `""` was counted as a suggestion. The fix strips the pair and records an empty-output abstention while retaining verbatim `rawOutput`; regression assertions cover empty quotes and backticks. Raw outputs were identical before and after the fix. Before the first run, Mac validation also caught an overly broad test substring assertion (`not a` matched the prompt's own wording); that assertion now checks the entire excluded source.

Validation at final code revision: 22 focused evaluation tests; 209 full Swift tests (22 evaluation plus 187 existing); 44 Python tests; fixture and no-feedback checks; signed Debug app build without installation; isolated recovery checks; Debug and Release executable builds. All passed. See [local validation report](validation.md). All three saved run directories pass `check-suggestion-results.py`; prompt SHA-256 values and record-to-prompt references were independently checked. Later changes in this PR only document and preserve this evidence. The current SDK reports a deprecation warning for `GenerationOptions(sampling:)`; builds succeed with the existing pinned API usage.

Run from the repository root:

```sh
swift build -c release --product jot-suggestion-eval
rev=$(git rev-parse HEAD)
corpus=docs/evaluation/contextual-suggestions/scenarios.json
.build/release/jot-suggestion-eval --corpus "$corpus" --output "work/suggestion-eval/$rev-normal" --iterations 3 --source-revision "$rev"
.build/release/jot-suggestion-eval --corpus "$corpus" --output "work/suggestion-eval/$rev-oracle" --mode oracle-context --iterations 3 --source-revision "$rev"
python3 scripts/check-suggestion-results.py "work/suggestion-eval/$rev-normal"
python3 scripts/check-suggestion-results.py "work/suggestion-eval/$rev-oracle"
```

Use new output directories for each invocation. The recorded runs used these executable arguments with the stated source revision and separate task output directories. Each directory below contains `run.json`, `results.jsonl` and `prompts.jsonl`:

- [Initial normal results](initial-normal/results.jsonl), before empty-quote handling was fixed.
- [Final normal results](normal/results.jsonl).
- [Final oracle-context results](oracle/results.jsonl).

The next decision for #79 is to improve and reevaluate user-role framing, grounded abstention and exact shell-command fidelity before implementing the Codex suggestion UI. This PR delivers the experiment and records that remaining quality gate; it does not implement the next product slice. No Jot installation or capture change was needed.
