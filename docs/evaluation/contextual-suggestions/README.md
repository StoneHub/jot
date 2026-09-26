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
- `suggest` has at least one included source. `idealText` and `pendingSuggestion` must say `"origin": "authored"`. `invalidate` requires a pending suggestion for the current input revision and a later input edit or deletion of one of its sources.
- The corpus covers every required case and includes at least one suggest, one abstain and one invalidate scenario.

Focused tests: `python3 -m unittest discover -s scripts -p 'test_*.py'`.

## Format (version 1)

`scenarios.json` holds `format`, `version`, `synthetic: true`, a shared `rubric` of criteria and `scenarios`. Each scenario has:

| Field | Meaning |
| --- | --- |
| `covers` | Coverage tags the scenario exercises |
| `target` | Integration, mode, field purpose, project/conversation/cwd, `inputRevision`, text before/after the cursor, `requestedAt` |
| `sources` | Context items with ID, kind, role, optional speaker, origin, scope, timestamp, revision, status (`current`, `stale`, `deleted`) and text; summaries list `derivedFrom` revisions |
| `expected` | `suggest`, `abstain` or `invalidate`; the sources retrieval should select or exclude, with a reason; optional authored `idealText` |
| `pendingSuggestion`, `change` | Invalidation only: an authored preview already shown, and what changed before acceptance |
| `scoring` | Applicable rubric criteria, a pass description and concrete `failIf` behaviors |

Source `status` is its state when the request is made. A change that occurs after the preview appears goes in `change`. Add an enumeration value in the validator when a new scenario needs one. Increase `version` only for an incompatible change of meaning.

## Mac experiment (not yet run)

The on-device evaluation is a separate Mac task. No harness or results exist yet. When it runs:

1. Record the corpus commit and version, Jot commit, macOS build, Mac model, AppleFM revision, the model and availability the framework reports, prompt template ID and SHA-256, generation options and context bounds.
2. For each scenario, evaluate retrieval and generation separately. Record the sources the implementation actually selects, and score them against `expected`. To isolate generation, also generate from exactly the expected included sources.
3. Simulate each `change` before acceptance and record whether the preview was withdrawn.
4. Store one record per scenario and run: `scenarioId`, `run` (`cold` or `warm`), `selectedSources`, `outcome` (`suggest`, `abstain`, `invalidate`, `error` or `timeout`), verbatim `outputText`, `timeToPreviewMs`, `scores` per applicable criterion (`pass`, `fail`, `not-applicable` or null while awaiting human review), `scorer` and `notes`. Use `scorer: null` for unreviewed semantic quality; do not convert missing reviews into pass results. Record deterministic source-selection comparisons separately from human semantic scoring.
5. Publish all actual outputs, including failures. Do not fill in a missing output or score, or describe any result as better than the one recorded.

Report cold and warm median and p95 time to preview separately from quality. A passing synthetic run is evidence for this corpus, not a product-quality claim; evaluation of real content remains local and scoped to the user.
