# Next ideas

The native app is the home for history, search, metrics, model information, and speaker labels. No separate dashboard or localhost service is planned. Issue #1 is superseded by this direction.

Useful next features, proposed rather than implemented:

- Recognition-level vocabulary biasing and learning from corrections. Explicit phrase replacements and preferred capitalization are available in Vocabulary.
- Retention settings and transcript export.
- Bookmarks for useful moments in a long conversation.
- Verified model installation with revision tracking and rollback. The current Models screen checks upstream publications; it does not automatically replace cached weights.


Other ideas remain optional: a local dictation cleanup model, enrolled speaker names across sessions, a phone microphone, and coordinator integration. Spoken replies are not part of this app's normal behavior.

## Proposed dictation controls

Configurable push-to-talk is implemented. A hands-free toggle shortcut or button and optional double-tap of the push-to-talk shortcut remain proposals. These are activation choices for dictation, separate from ambient transcription.

The built-in macOS microphone indicator is sufficient listening feedback for Monroe. No additional menu-bar animation or fixed bottom-of-screen bar is requested. Consider cursor animation only if a supported public macOS API allows it while dictating in other apps; do not substitute a cursor-following overlay. AppKit cursor APIs cover app-owned views, and a supported cross-app cursor-animation API has not been established. Keep Finish and Cancel accessible from the controls.

Recommended behavior: insert only on explicit finish into the original field. If focus moves to another field or app, stop and retain the draft for recovery without automatic insertion. Ambient remains history-only. Longer hands-free sessions require revisiting the current 60-second dictation buffer and adding bounded incremental processing; changing the gesture alone must not remove that limit.

This is a proposal from the vocabulary task discussion, not implemented behavior. Wispr Flow's [hands-free guide](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free), checked 2026-09-07, describes configurable shortcuts, double-tap activation, stop-to-paste, and Esc cancellation. Its precise desktop behavior on a mid-session focus change was not established by that guide.
