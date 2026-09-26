# Draft from the current field

Status: proposed next implementation slice, September 26, 2026. Parent: [#79](https://github.com/StoneHub/jot/issues/79). The user confirmed that double-Fn invocation and Tab insertion work in the installed PR #89 candidate, but the output still restates the field hint. Interaction success does not establish useful suggestions.

## Product direction

Jot is a general writing assistant across compatible computer text fields. Codex is the primary validation target, not the architectural boundary. The base capability must use the current field without requiring a Codex hook or any other app-specific integration. Native/browser adapters can add correctly attributed surrounding conversation or document context later. Support must be demonstrated per field capability; password, inaccessible and incompatible controls are not promised universal support.

## Brain dump behavior

The user can type or dictate rough notes, intent, facts and constraints into the target field, then double-tap Fn to turn that material into a useful draft. This must work with no transcript history, no chat integration and listening paused.

Proposed default: if a range is selected, use and replace that selection. Otherwise, use the current field contents as the seed and preview a replacement of the whole draft. Label the preview as a rewrite so acceptance is clear. Merely displaying the card leaves all original text untouched. Tab replaces only the original, unchanged range. Typing, Escape, selection changes or focus changes dismiss it. Never append a polished copy after the rough notes, and never send or execute anything.

Example seed: "reply to alex — can help saturday after 2, ask what tools to bring, keep it casual"
Example useful draft: "Hey Alex, I can help Saturday after 2. What tools should I bring?"

The seed establishes intent. Preserve supplied facts and constraints; do not invent commitments, missing answers or personal preferences. Keep generated text separate from later user-authored/submitted context to avoid self-reinforcement.

## Context selection and output quality

1. Start with genuine user-entered field text or the explicit selection. Placeholder/help text is not a seed. Reject ambiguous AX value/placeholder metadata rather than treating UI hints as instructions.
2. Add surrounding conversation/document context only when author roles and the current target association are established. The globally latest chat is not necessarily the focused chat.
3. Add Jot speech only when selected by the user or meaningfully associated with this task. Recency alone must not import unrelated ambient speech into a rewrite.
4. With a blank field and no usable associated context, explain that Jot needs a few rough notes. Do not generate a paraphrase of the hint. With a seed, zero transcript rows must not block generation.
5. Evaluate relevance and transformation, not merely valid output or successful insertion. The current exact-echo guard cannot establish that a paraphrase is useful.

## Implementation and acceptance

- Add a seed-drafting mode with an explicit replacement range, while retaining separate continuation/reply/shell semantics where actually requested. No inference that a nonempty field is always an append-only continuation.
- Reuse the shared local model gate, source bounds, cancellation, field identity and exact readback checks. Keep inference local and double-Fn request-only.
- Add focused synthetic cases before tuning: seed-only rough notes, selected text within a larger field, literal placeholder words actually typed, true empty hint, unrelated ambient transcripts, missing preferences, and stale same-length edits.
- Run the normal/oracle evaluation for each prompt change and preserve actual outputs without changing existing expectations to hide regressions.
- Prove useful changed output and exact Tab replacement with no duplication or send in a native editor and browser composer, then Codex. Keep unsupported capability cases explicit.
- Rich app-context ingestion is a follow-up enhancement, not a prerequisite for seed drafting. Keep per-conversation association as a separate verified contract.

No application code, global hooks, browser extensions or capture settings are changed by this planning document.

## Source patch: drafting and visible conversation (September 26, cloud)

Prepared in a Linux cloud session and stacked on PR #89. Uncompiled: every Swift gate below still has to pass on the Mac.

**Behavior.** Double-tap Fn (or the optional shortcut) in a field:

- Notes in the field become a **draft**. A selection with text is the seed; otherwise the whole field is. The card says "Draft from your notes" (or "Rewrite of your selection"). Tab selects exactly the seed range, checks that the selection took, then inserts over it through the existing verified path. A field that will not take the selection gets its caret back and nothing is replaced. Transcripts are not read, so this works with listening paused and no history. Undo in the target app restores the notes.
- A **blank** multi-line field gets a reply only with associated context: the visible conversation above it, or recent dictation for a blank Codex composer (as in #89). Ambient speech is no longer imported by recency. With neither, or in a single-line field, the card asks for rough notes instead of generating. When the only visible text is a greeting or starter prompts, the prompt tells the model to abstain.
- **The latest meeting** (speech from the latest session in the last 30 minutes) is never added by recency alone. When one exists, the card offers **Use meeting ‘Title’**. Clicking it asks again for the same field with the meeting included (larger bound: 12 sources, 5,000 bytes), and the button then reads **Without the meeting**. **Tuning → Include the latest meeting** (off by default) makes it part of every request. The card takes mouse clicks only while it shows this choice. It is a nonactivating panel that never becomes key, so the target field keeps focus; keys keep their meanings. A notice with the choice stays for 8 s instead of 2 s. Meeting rows are revalidated before Tab like other stored rows, so a live meeting whose rows are still being cleaned can withdraw the card.
- Outputs that repeat the notes, restate the field hint (all its words plus a few more) or copy text already on screen show a short notice instead of a card.

**Chat context.** `ScreenContextReader` reads the focused window through Accessibility when a request is made, off the main thread, with a 50 ms per-call timeout and a 400 ms / 3,000-element budget. It walks the field's web area (browser and Electron apps) or its window, newest content first, and keeps static text that is visible, entirely above the field and in the field's column, so a sidebar or another chat's preview is excluded by position. Other inputs and password fields are never read. At most 2,400 bytes nearest the field go to the prompt as one source, labeled as visible text whose authors are not identified. Nothing is stored or logged; diagnostics record only whether screen text was used. **Tuning → Use visible conversation** turns it off.

This does not establish author roles, which the plan above sets as the bar for richer context. It is position-associated rather than role-attributed, and the prompt says so. Per-app role adapters and Codex hooks remain follow-ups.

**Field hints.** Web editors often draw the hint as CSS text inside the editable element, which Chromium reports as the field's value. This is the likely cause of the hint-restating output. A short value is now treated as blank when it consists only of text under a descendant whose `AXDOMClassList` marks a placeholder (`placeholder`, `is-empty`, `is-editor-empty`). The result is cached per field and value. The Codex composer's actual attributes are unverified: check them with Accessibility Inspector and record what it shows.

**Engine.** `SuggestionMode.draft`, `Target.seed`/`window`, `SuggestionPlan`, `FieldHint`, `ScreenContext`, `SuggestionAttribution`, `SuggestionOutput.review` and a per-call `ModelCallGate` deadline (8 s for drafts, 3 s for replies). Prompt `jot-suggestion-v4` adds draft instructions and the screen-text description. Reply, continuation and shell-command prompts without screen text are byte-identical to v3, so the September 25 runs remain the comparison. Draft output may have paragraphs and gets up to 400 response tokens, scaled to the notes. A single-line field rejects multi-line output.

**Not in this patch.** Draft scenarios in the evaluation corpus. The corpus requires every suggestion to cite a source, and several corpus tests assume it. Adding seed-only cases needs a checker rule and test changes that should be compiled together.

### Mac gates

```sh
swift test --filter SuggestionEvaluation     # includes SuggestionEvaluationDraftTests
swift test
python3 scripts/local-pr-check.py <PR> --filter SuggestionEvaluation
./scripts/build-install.py --configuration Release --build-only
```

No files were added to `Sources/Jot`, so `project.yml` and `Jot.xcodeproj` are unchanged. `ScreenContextReader` lives in `SuggestionCoordinator.swift`, which `JotRecoveryChecks` already compiles.

### Live acceptance

1. TextEdit, a browser textarea, then Codex: type the Alex example seed, double-tap Fn. The draft keeps Saturday, 2 and the tools question, adds nothing, and Tab replaces the notes without duplicating them or sending.
2. Select one line of a longer draft and request. Only that line is replaced.
3. Type a character, press Escape, or switch fields while the card is visible. Nothing is inserted. A same-length edit before Tab inserts nothing.
4. Blank TextEdit document, or a new empty Codex chat: "Jot needs a few rough notes…", not a hint paraphrase.
5. Blank Slack or Messages composer under a real question: a reply to the latest message, with the source line "Text on screen". The sidebar and other chats do not appear in it.
6. Blank Codex composer under a Codex question: a reply, not a copy of the question.
7. Search or URL field with notes: a one-line draft. Password field: no card.
8. Turn off **Use visible conversation**: diagnostics show `screenContext: false` and step 5 asks for notes.
9. Codex composer in Accessibility Inspector: record the hint element's role and `AXDOMClassList`, and confirm a blank composer reads as blank.
10. With a titled meeting in the last 30 minutes, request a draft: the card offers "Use meeting ‘Title’". Click it without moving focus: the field stays focused, a new card cites the meeting (`meetingContext: true`), and Tab still replaces the notes. "Without the meeting" asks again without it. With no recent meeting there is no button, and clicks pass through the card. Turn on **Include the latest meeting**: the first card already cites it.
