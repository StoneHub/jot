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
