# Local task: contextual suggestions inside Jot

For the local agent on Monroe's Mac. Part of [#79](https://github.com/StoneHub/jot/issues/79); follows [#86](https://github.com/StoneHub/jot/issues/86) / [#87](https://github.com/StoneHub/jot/pull/87). This is step 2 of [the design](../CONTEXTUAL-SUGGESTIONS.md#delivery-sequence), the Codex vertical slice.

Monroe decided on 2026-09-26, after the first Mac run:
- Build the feature into Jot now, with real context and real insertion, instead of stopping at a standalone harness.
- Do it on the Mac, where it can be built, seen and debugged.
- Tab accepts a visible suggestion.

## Outcome

In a text field (Codex first, any ordinary native field too), the user presses the suggestion shortcut. Jot reads the field's draft and recent Jot context, and a card at the field shows a suggested next input with its sources. **Tab** inserts it through Jot's verified insertion. **Escape**, typing, or a change of focus or source dismisses it. Nothing is ever sent, submitted or executed. Listening and capture are unaffected.

## 0. Start from the Mac results

#87 passed its Mac gates at `a6c32b2`, and its [first Mac run](../evaluation/contextual-suggestions/results/2026-09-25-mac/README.md) is recorded:
- Retrieval matched 12/12.
- Warm generation took about 420 ms median.
- Generation quality is not yet good enough: the model invents a preference (`tabs`), repeats the assistant's question as the user's reply, adds an unsupported argument to a named command, and returns empty drafts.

Merge #87 under `AGENTS.md`. It adds a standalone executable and does not change the installed app.

Monroe chose to build the UI now anyway, so these failures can be seen and debugged in the real app. Do not wait for prompt quality. In parallel, treat the recorded failures as prompt work: user-role framing, grounded abstention, and exact command fidelity. The eval is the regression bar. After each prompt change, rerun both modes into new output directories and record the outputs alongside the September 25 run. Never edit the corpus expectations to make a run pass. The current SDK warns that `GenerationOptions(sampling:)` is deprecated; switch to its replacement if the pinned AppleFM API allows it.

## 1. Shared engine in JotCore

Move the reusable parts of `Sources/JotSuggestionEvaluation` into `Sources/JotCore`: the source and target types, `SourceSelector`, `SuggestionPrompt`, `SuggestionOutput`, `Preview`, `ModelCallGate` and the AppleFM `generate` adapter. Make public only what the app needs. The eval stays a thin runner over JotCore and keeps corpus decoding, records and output files. Its tests move with the code, and `swift test --filter SuggestionEvaluation` must still pass. Keep the AppleFM pin.

Add one engine change: an **explicit-request association**. Pressing the shortcut means the user chose to use recent Jot context, so those rows count as associated even without project or conversation metadata. Do not relabel them as pinned selections. The corpus scope rules stay as they are for the eval.

## 2. Request path in the app

- **Trigger.** Add a second shortcut using the existing `DictationShortcut` model and the `ShortcutSettings` sheet. Choose it with Monroe so it is free on his Mac. Handle it in `DictationInput.handle`: that event tap is already `.defaultTap` and can consume events, so do not add a second tap. Ignore the shortcut while dictation is recording or delivering.
- **Target snapshot.** Use `captureTarget()`, which already fails closed on password fields, and a read-only form of the existing private `snapshot()` to get the text before and after the cursor. Derive the input revision from the exact value and selection. Compare text, never length.
- **Mode.** A blank Codex composer (bundle ID plus `AXTextArea`) is `reply`. A non-empty draft in any field is `continuation`. A blank field in other apps abstains: search, URL and unknown fields don't establish that they want a reply.
- **Context.** Take rows from `TranscriptStore`: recent dictation plus the latest session, from the last 30 minutes. Dictation rows are the user's words (`role: user`). Ambient rows are `participant`, with their `speakerLabel` or "unlabeled speaker". Jot does not know which ambient speaker is Monroe, so never treat an ambient row as the user's own words. The engine's bounds (6 sources, 4 KiB) apply.
- **Generation.** Run it off the main thread through the shared gate: one outstanding request, a 2 s deadline, cancelled on dismissal. It must never resume listening, load speech models or block capture.
- **Privacy.** Keep prompt, context and output text out of logs and `diagnostics`; record counts and outcomes only.

## 3. Card and Tab acceptance

- **Card.** A nonactivating panel follows `DictationInput.targetFrame()`, like `DictationHighlight`. It uses the accent color, Liquid Glass with the material fallback from `AGENTS.md`, the suggestion text, a short source line (for example "Recent dictation + meeting 'Standup'") and the hint "Tab to insert · Esc to dismiss". Show a brief loading state. For an abstention, error or timeout, show a short "No suggestion" instead of failing silently.
- **Tab.** Consume the Tab key-down and its key-up only while a card is visible for the captured field and no other key arrived since the snapshot. Tab with modifiers, repeat, and every Tab without a card pass through untouched. Keep AX reads out of the tap callback.
- **Accept.** After consuming Tab, re-read the field and sources. Insert only if the value and selection exactly match the snapshot and every source row still exists unchanged. Use the existing `insert(_:)` path, which verifies and never presses Return. On a mismatch, insert nothing and say so briefly.
- **Dismiss.** Escape (consumed only while a card shows), any other key (passed through), a focus or app change, deleting or clearing a source row, or about 30 s without action.
- Put the key decision in a pure type, like `ShortcutTracker`, so consume, pass-through and dismiss are unit-tested without AX.

## 4. Build hygiene

- New files in `Sources/JotCore` or `Sources/Jot` need `xcodegen generate` and the regenerated `Jot.xcodeproj` committed, as `build-install.py` does.
- `JotRecoveryChecks` lists `Sources/Jot` files one by one in `project.yml`. Add any new file that `DictationInput`, `SpeechService` or the coordinator depend on, and keep the recovery checks passing.

## Gates

- `swift test` in full, with the moved and new focused tests.
- `python3 scripts/local-pr-check.py <PR> --filter SuggestionEvaluation`.
- `./scripts/build-install.py --configuration Release --build-only`.
- Recovery checks.
- Then install under `AGENTS.md`, preserving capture, transcript selection and history.

## Visual acceptance on the installed build

Do these in the running app; this is where the bugs will show. Keep screenshots and recordings with real content local.

1. A blank Codex composer, with a recent dictation stating what you want to ask. The card appears at the field within the 2 s deadline, with the right source line. Note whether the text is in your voice. The eval's role failures may show up here, and each one is a finding to record.
2. Tab inserts exactly that text. Codex does not submit.
3. Type one character while the card shows. The card is gone and the next Tab behaves normally.
4. A same-length edit (replace a word with one of equal length), then Tab. Nothing is inserted.
5. Switch field, window or app. The card is gone.
6. Escape dismisses the card. Escape and Tab work normally when no card shows, including in Codex and a browser.
7. Password field: no card. IME composition (Pinyin or Japanese): Tab is not stolen.
8. Delete the source transcript in Jot while the card shows. The card is withdrawn.
9. Press the shortcut while dictating. Nothing happens, listening is unchanged, and there is no audio gap.
10. The card follows the field on a second display and when the window moves.
11. With the model unavailable, or with Apple Intelligence off, a clear notice appears and nothing hangs.

## Out of scope

Automatic or focus-triggered suggestions, inline ghost text, the browser extension, Terminal migration, Codex hooks or MCP context ingest, and speaker self-identification. Record anything these tests reveal about them for later.
