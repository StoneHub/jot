# Fn dictation when the window is closed

The shortcut is currently fixed to Fn/Globe. The global listener belongs to the application service; closing the main window changes the app's activation policy but does not explicitly disable the listener.

For a failure in another app, run `/Applications/Jot.app/Contents/Helpers/jot doctor` before and after a failed Fn attempt. The `dictationInput` object contains only listener health and counters, not transcript or field text:

- `eventTapEnabled`: the live macOS event-tap state, separate from the selected Fn preference.
- `fnPresses`: unmodified Fn press transitions observed since launch.
- `acceptedPresses`: presses that passed the readiness and focused-field checks.
- `busyPresses`: presses rejected by the service readiness check.
- `lastError`: the last shortcut/focus error; cleared when a press is accepted.

Focus the same editable field and compare an attempt with Jot's window open to one with it closed. If presses do not increase, the failure precedes target capture. If presses increase but accepted presses do not, inspect busy presses and the error. If accepted presses increase, inspect the top-level notice and lastDelivery for later capture or insertion failures. Avoid sharing transcript/history output when reporting this issue.

The reported Claude Code Desktop failure has not yet been reproduced. The available UI automation cannot synthesize Fn. These diagnostics support a physical-key check on the affected Mac; they are not a claim that the issue is fixed.

# Dictation cleanup

Fn delivery removes standalone `uh` (case-insensitive) and adjacent filler punctuation/spacing after applying personal vocabulary. History retains the original recognized text. Compounds such as `uh-huh` and `uh-oh` are preserved. Filler-only output inserts nothing. Ambient transcripts and meeting exports are unaffected.
