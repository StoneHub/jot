# Next ideas

The native app is the home for history, search, metrics, model information, and speaker labels. No separate dashboard or localhost service is planned. Issue #1 is superseded by this direction.

Useful next features, proposed rather than implemented:

- Recognition-level vocabulary biasing and learning from corrections. Explicit phrase replacements and preferred capitalization are available in Vocabulary.
- Retention settings and transcript export.
- Bookmarks for useful moments in a long conversation.
- Verified model installation with revision tracking and rollback. The current Models screen checks upstream publications; it does not automatically replace cached weights.
- [Explore microphone proximity and loudness for intentional-speaker detection (#33)](https://github.com/StoneHub/jot/issues/33). Test near/far and noisy-room behavior before considering any speech filtering. Recovery includes every voice by default.


Other ideas remain optional: a local dictation cleanup model, enrolled speaker names across sessions, a phone microphone, and coordinator integration. Spoken replies are not part of this app's normal behavior.

## Proposed dictation controls

Configurable push-to-talk and double-tap recovery are implemented. Resume starts continuous listening. Double-tap retries an undelivered dictation first, otherwise inserts the configured recent speech window into the current field. A hands-free toggle for a specifically marked dictation remains a separate idea.

The built-in macOS microphone indicator is sufficient listening feedback for Monroe. No additional menu-bar animation or fixed bottom-of-screen bar is requested. Consider cursor animation only if a supported public macOS API allows it while dictating in other apps; do not substitute a cursor-following overlay. AppKit cursor APIs cover app-owned views, and a supported cross-app cursor-animation API has not been established. Keep Finish and Cancel accessible from the controls.

Delivery remains explicit: release a held shortcut into its original field, or double-tap to choose the current field for recovery. Focus changes retain the dictation for retry. Recognition is incremental so long holds do not depend on a 60-second audio buffer.

The original hands-free proposal came from the vocabulary discussion. Jot's double-tap now means recovery/recent insertion, not start/stop hands-free recording.
