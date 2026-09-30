# Jot 0.2.10

Jot stays responsive while loading large histories and saving speech. Store queries, Live-feed grouping, recognition saves, cleanup, recovery and speaker edits now run off the main thread in submission order. Changing the selected session while a read is pending keeps the latest selection; delayed updates use the current saved text without duplicating rows.

The dictation shortcut runs on its own event-tap thread. Target lookup is asynchronous with short timeouts, and a late lookup is rejected after the app or field changes. A failed session deletion preserves speech still being recognized; a successful deletion prevents late results from recreating the session. Updates wait for pending storage and speaker work.

The underlying modules now take their sibling dependencies directly, with separate files for store data types, shortcut handling and screen-context reading.

Development prerelease, signed with Monroe's Apple Development identity; not notarized. Requires a Mac that trusts this development certificate. Basic app support starts at macOS 14; Apple Intelligence enhancements require compatible hardware and macOS 26 or later. Transcripts and audio stay on the Mac. Models download separately.

Validation: 346 Swift tests, 48 Python tests, signed Debug/Release builds and recovery-controller checks passed. Generated speech exercised the real recognition and cleanup models. A 7,000-row history load measured a 1.35 ms longest main-thread gap; a speaker pass and Regroup over 3,000 rows dropped no audio in the synthetic listening check.

Test when you sit down: hold and release Fn in native and Electron fields, try a rapid tap, double-Fn suggestion and Tab acceptance, and switch fields during target lookup. Switch Sessions and search while speech is saving; rename, regroup and export a saved session. Physical Fn and cross-app insertion remain user checks.
