# SwiftUI feedback in Porch Speech

Debug builds include an in-app feedback picker. The main Transcripts window is tagged by screen and by meaningful controls: service actions, navigation, history search/visibility, resource metrics, tuning controls, and model checks.

Pick mode selects a feedback target instead of activating the underlying control. Notes and acceptance checks are saved locally; selected notes can be exported as Markdown or JSON for a coding task. Target metadata uses stable control IDs, developer-written labels, and source file/line. The host does not pass transcript text, search terms, speaker names, or recording identifiers to the feedback package.

The overlay is attached once to the main window. The menu-bar popover keeps its normal controls. Release builds use the package's no-op modifiers.

`Vendor/DevFeedback` is an unchanged snapshot of the reusable package from the webDevFeedbackExt project. Its upstream revision and source path are recorded alongside the snapshot. Changes to the reusable package belong in that canonical project before refreshing the vendored copy.

## Manual check

1. Open the native app and enter feedback pick mode.
2. Pick Fn dictation; confirm the Fn toggle does not change.
3. Add a test note and an acceptance check, save it, and reopen it from feedback History.
4. Export only that note as Markdown and JSON. Confirm the control ID, source location, note, and acceptance check are present, without transcript content.
5. Exit pick mode and confirm ordinary navigation and controls work again.

Keep test notes clearly marked as test data. Saving local feedback is separate from asking an agent to act on it; exports are input for a user-directed task.

## Transcript history in Finder

History → Open History in Finder selects `~/Library/Application Support/PorchSpeech/transcripts.sqlite3`. Quit Porch Speech before moving the database and any matching `-wal` / `-shm` files to Trash; Pause unloads models but keeps the database open. The next launch creates an empty database if the previous one was removed. This action only reveals files; it does not delete anything or open transcript contents.
