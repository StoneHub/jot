# Contextual-suggestion scenarios

Synthetic scenarios for step 1 of [contextual suggestions](../../CONTEXTUAL-SUGGESTIONS.md), the context-and-quality experiment ([#79](https://github.com/StoneHub/jot/issues/79), [#81](https://github.com/StoneHub/jot/issues/81)). They fix the expected source selection, outcome and scoring rubric before any prompt is tuned. The people, projects, paths and conversations are invented. Expected results and `idealText` are authored synthetic test expectations, prepared with coding-agent assistance. They are not outputs from a Jot suggestion run or measured results.

## Validate

```sh
python3 scripts/check-suggestion-fixtures.py
```

It exits 0 for a valid corpus and 1 otherwise. Pass a path to check another file. The check is structural only: a valid corpus says nothing about suggestion quality.

It enforces the version, unique scenario/source/rubric IDs, known enumerations, no unknown keys, and resolvable references (`includedSources`, `excludedSources`, `derivedFrom`, `duplicateOf`, pending/changed sources, rubric criteria). It also checks the corpus's own rules:

- Every source is either included or excluded. Included sources are current, from the target's project unless pinned, not duplicates and not shown suggestions.
- An exclusion reason matches the source: `stale`, `deleted`, `duplicate` (`duplicateOf`) and `generated-not-intent` (`shown-suggestion`). A summary of an older revision or of a deleted source cannot be current.
- `suggest` has at least one included source, except in `draft` mode, where the user's notes are the grounding. A `draft` target, and only a `draft` target, has non-empty `seed` notes. `idealText` and `pendingSuggestion` must say `"origin": "authored"`. `invalidate` requires a pending suggestion for the current input revision and a later input edit or deletion of one of its sources.
- The corpus covers every required case and includes at least one suggest, one abstain and one invalidate scenario.

Focused tests: `python3 -m unittest discover -s scripts -p 'test_*.py'`.

## Format (version 1)

`scenarios.json` holds `format`, `version`, `synthetic: true`, a shared `rubric` of criteria and `scenarios`. Each scenario has:

| Field | Meaning |
| --- | --- |
| `covers` | Coverage tags the scenario exercises |
| `target` | Integration, mode, field purpose, project/conversation/cwd, `inputRevision`, text before/after the cursor, `requestedAt`. A `draft` target also has `seed`, the user's rough notes that the result replaces; `before` and `after` are then the field text around the notes |
| `sources` | Context items with ID, kind, role, optional speaker, origin, scope, timestamp, revision, status (`current`, `stale`, `deleted`) and text; summaries list `derivedFrom` revisions |
| `expected` | `suggest`, `abstain` or `invalidate`; the sources retrieval should select or exclude, with a reason; optional authored `idealText` |
| `pendingSuggestion`, `change` | Invalidation only: an authored preview already shown, and what changed before acceptance |
| `scoring` | Applicable rubric criteria, a pass description and concrete `failIf` behaviors |

Source `status` is its state when the request is made. A change that occurs after the preview appears goes in `change`. Add an enumeration value in the validator when a new scenario needs one. Increase `version` only for an incompatible change of meaning.

## Evaluation harness

`jot-suggestion-eval` ([`Sources/JotSuggestionEvaluation`](../../../Sources/JotSuggestionEvaluation), [#86](https://github.com/StoneHub/jot/issues/86)) runs this corpus against the on-device model. The [September 25 Mac validation and actual outputs](results/2026-09-25-mac/README.md) establish compilation, tests and completed normal/oracle-context runs. Retrieval matched the corpus, but generation failed several semantic expectations; the experiment does not establish readiness for a suggestion UI. It reads only the corpus you name and writes only to a new output directory. It never connects to Jot, reads transcripts, inserts text or runs commands.

- **Input only.** Each scenario is decoded, then projected to its target snapshot and sources. Selection, prompts and generation never receive titles, coverage tags, expected selections, the expected outcome, `idealText` or scoring. The authored `pendingSuggestion` text is not decoded. The expectations are read after the outcome is final, for the deterministic comparisons below.
- **Modes.** `normal` selects sources itself. `oracle-context` generates from exactly `expected.includedSources`, isolating the model from retrieval. Every record and `run.json` names its mode; keep the two in separate output directories.
- **Selection.** A deterministic rule set that checks status, revision and provenance, duplicates, shown suggestions and scope. A pin is explicit association. Otherwise a known project or conversation must match, and a conflicting one excludes the source. Time orders sources only when the bounds force a choice. The bounds are at most six whole sources and 4096 UTF-8 bytes. Sources are never truncated. If nothing is selected, the scenario abstains before inference, except a draft, which is generated from its notes alone. The selector uses no scenario IDs. A focused test checks that its rules reproduce this corpus's authored selections.
- **Generation.** Prompt template `jot-suggestion-v1`, with mode-specific instructions to draft the user's own next input and `NO_SUGGESTION` to abstain. Source text is JSON-quoted as data. Each request uses the pinned AppleFM `generate` API in a fresh session, with greedy sampling, 128 response tokens, one outstanding request and a two-second deadline. A draft gets 128–400 response tokens, scaled to its notes, and the app's eight-second deadline. After a timeout the harness waits up to two more seconds for the cancelled request to return. If it has not returned, the run stops (exit 3) rather than start a request that could overlap it.
- **Changes.** For the invalidation scenarios, the corpus `change` is applied after the preview. The record shows whether the generated preview and the authored preview were withdrawn. Freshness compares the exact draft text and revision, so a same-length edit is caught.

### Mac gate

```sh
swift test --filter SuggestionEvaluation
swift test
swift build --product jot-suggestion-eval
```

`python3 scripts/local-pr-check.py <PR> --filter SuggestionEvaluation` runs the first two with the portable checks. Run the product build separately.

### Run

From a clean checkout root, one output directory per invocation (`work/` is ignored by Git):

```sh
python3 scripts/check-suggestion-fixtures.py
rev=$(git rev-parse HEAD)
corpus=docs/evaluation/contextual-suggestions/scenarios.json
swift run -c release jot-suggestion-eval --corpus "$corpus" --output "work/suggestion-eval/$rev-normal" \
  --iterations 3 --source-revision "$rev"
swift run -c release jot-suggestion-eval --corpus "$corpus" --output "work/suggestion-eval/$rev-oracle" \
  --mode oracle-context --iterations 3 --source-revision "$rev"
python3 scripts/check-suggestion-results.py "work/suggestion-eval/$rev-normal"
python3 scripts/check-suggestion-results.py "work/suggestion-eval/$rev-oracle"
```

The executable exits 0 when every scenario ran, 1 for a usage, input or output error, and 3 when it stopped early. It refuses an existing output directory and a corpus not marked `synthetic`. The validator is stdlib-only. It exits 0 for a valid complete run, 1 for invalid output and 3 for a valid but incomplete run. It checks structure and consistency and never assigns scores.

### Output

| File | Contents |
| --- | --- |
| `run.json` | Run ID, mode, iterations, start/finish, completion or stop reason; corpus path, SHA-256 and version; `--source-revision`; macOS version string, hardware model, AppleFM availability and pinned revision; bounds, generation options and per-mode instruction hashes. `modelRevision` stays null because Apple does not expose one. |
| `results.jsonl` | One record per iteration and scenario, in run order |
| `prompts.jsonl` | Each distinct instruction/prompt pair once, with its hash, so a reviewer can see exactly what the model received |

Every record has the same keys; an absent value is `null`.

| Field | Meaning |
| --- | --- |
| `runId`, `iteration`, `mode`, `scenarioId`, `generator` | Attribution. `generator` is `apple-fm`, or `test-fake` for records made by an injected test generator |
| `run` | `cold` for the first request this process sent to the model, `warm` after, `null` when no request reached the model. The system may already have had the model loaded; each invocation yields one cold sample. |
| `selectedSources`, `excludedSources` | Source IDs with revision, or with the exclusion reason |
| `outcome`, `detail` | `suggest`, `abstain`, `invalidate`, `rejected` (output failed presentation checks, such as a multi-line shell command), `unavailable`, `error` or `timeout`, with a reason such as `no-selected-source`, `model-abstained` or an AppleFM availability value |
| `rawOutput`, `outputText` | The response exactly as returned; the trimmed suggestion text, kept for a withdrawn preview |
| `change` | For invalidation scenarios, whether the generated and the authored preview were withdrawn |
| `timeToPreviewMs`, `generationMs`, `durationMs` | Time from request to preview (suggest and invalidate only), the model call alone, and the whole scenario |
| `promptSHA256` | SHA-256 of the instructions, a blank line and the prompt |
| `selectionComparison`, `outcomeComparison` | Deterministic comparisons with the authored expectations. Selection has none in oracle-context mode. These are not quality scores. |
| `scores`, `scorer`, `notes` | One entry per applicable criterion, all `null` until a person reviews the output. A reviewer records `pass`, `fail` or `not-applicable` and names themselves in `scorer`. |

### Review

Publish all actual outputs, including failures, timeouts and unavailable runs. Do not fill in a missing output or score, or describe any result as better than the one recorded. Report retrieval (`selectionComparison`), generation quality (human `scores`) and latency separately. For latency, give cold and warm median and p95 of `generationMs` and `timeToPreviewMs`, with sample counts. A passing synthetic run is evidence for this corpus, not a product-quality claim; evaluation of real content remains local and scoped to the user.
