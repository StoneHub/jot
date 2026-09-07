# UI feedback

Debug builds provide **Developer → Pick UI for Feedback** (⌘⌥⇧F) and **Developer → Feedback History**. The picker has no persistent button or reserved space in the app. While picking, highlighted targets intercept clicks so ordinary controls do not activate.

Notes stay local. Review selected notes before exporting Markdown or JSON. The picker records static target labels, source locations, and bounds; it does not collect screenshots or view text.

## Host integration

Keep `import DevFeedback` and `FeedbackCommands()` inside `#if DEBUG`. Attach `.feedbackOverlay(appID: "jot", screen: ...)` to the main scene content. Release uses local no-op modifier shims and does not generate row keys.

Tag search, view-mode selection, the text document, each card, mode/speaker label, timestamp, text body, copy indicator/action, and speaker-name action. Repeated cards use opaque per-view UUIDs, with transcript IDs used only as internal lookup keys. Labels stay static. Tags on containers must preserve child targets; verify both a child and parent whitespace pick. Apply `.feedbackViewport()` to each ScrollView itself so offscreen targets cannot draw or receive picks over neighboring controls.

The package is an unchanged snapshot from the committed revision in `Vendor/DevFeedback/UPSTREAM.md`. Make reusable fixes upstream, then refresh it. Run the package tests and Release build after a refresh.

## Release check

`./scripts/build-install.py --configuration Release --build-only` builds and verifies a signed product without interrupting the installed app. It rejects `DEBUG` and known feedback UI, storage, and target-metadata markers in bundled Mach-O binaries. Evidence is written to `build/release-proof.json`. This is a development-tool exclusion check, not notarization or proof of installation on another Mac.

## History in Finder

History's folder button selects `~/Library/Application Support/Jot/transcripts.sqlite3`. Quit Jot before moving the database and its matching `-wal` / `-shm` files. The next launch creates an empty database if it was removed. The button only reveals the file.
