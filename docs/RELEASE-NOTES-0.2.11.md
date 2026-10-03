# Jot 0.2.11

Dictation now shows the field outline as soon as its target is found, and the processing wash loops until insertion finishes. Very short filler-only holds and ambient backchannels such as “Yeah” and “Mm-hmm” are filtered more carefully. Empty recognition results avoid unnecessary store work, and speaker processing runs at utility priority.

Setup, model-download, permission and recovery guidance remain reachable in narrow windows, including the compact icon rail. Speech and suggestion modules now receive their dependencies explicitly, and one-shot model completion handling is shared.

Adds an optional Claude Code jot-transcripts plugin for reading local Jot sessions. The plugin is installed separately; explicitly requested transcript excerpts can be sent to Claude's model. Optional window-image suggestions remain pending in PRs #166 and #185 and are not included.

Development prerelease, signed with Monroe's Apple Development identity; not notarized. Requires a Mac that trusts this development certificate. Basic app support starts at macOS 14; Apple Intelligence enhancements require compatible hardware and macOS 26 or later. Capture and stored history remain local; models download separately.

Test when you sit down: hold and release Fn in a native and an Electron text field and watch the outline and processing wash; try a short filler-only hold, double-Fn suggestions and Tab acceptance. Check setup and recovery controls in a narrow window. If using the new plugin, install it separately and ask Claude to list recent Jot sessions.

Validation: 348 Swift tests, 78 Python tests, 27 structural suggestion-fixture scenarios, signed Debug build and isolated recovery-controller checks passed on current main. Generated speech also passed the real-model audio recovery path. Release packaging runs the Swift tests again and verifies the exact signed Release product. Native window checks also passed for setup, permission and recovery guidance at 719 points wide and 520 × 420. Physical Fn and cross-app insertion remain end-to-end user checks.
