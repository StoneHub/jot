# Jot 0.2.12

Optional window images can now ground explicitly requested suggestions when Accessibility misses visible content. Enable Include window image in Suggestions settings to use it; it stays off by default. Screen Recording access is requested only when enabling the option. Images are captured once per request, kept in memory, and processed by the on-device model. No screenshot history is saved.

The image spans the actual field's horizontal column, from the window top through the field, clipped to the matched window. It never widens or shifts horizontally, and horizontal pixel rounding stays inside that column. This is a geometric boundary, not a guarantee that every application's layout separates conversations by columns.

Ambiguous window matches are rejected. Dismissal cancels capture, stale requests cannot supply newer requests, and late native values are discarded. Unsupported or rejected images fall back to text when existing selected sources or a rewrite seed ground the request. Source attribution and receipts reflect whether an image was actually used.

Development prerelease, signed with Monroe's Apple Development identity; not notarized. Requires a Mac that trusts this development certificate. Basic Jot support starts at macOS 14; Apple Intelligence text enhancements require compatible hardware and macOS 26 or later. Image input requires macOS 27 and a model supporting images; text behavior remains available without image support.

Validation: 374 Swift tests, 78 Python tests, 27 structural fixture scenarios, signed Debug/Release builds and isolated recovery checks passed. The actual real-model audio recovery path passed with generated speech. Three native synthetic-window captures excluded the neighboring sidebar and supplied the visible meeting time correctly to the on-device model. Capture plus the bounded question measured 1.38 seconds first and about 0.47 seconds warm. These are probe timings, not the full production suggestion coordinator.

Test when you sit down: enable the optional image setting and follow the Screen Recording permission flow; double-Fn a suggestion and accept with Tab in native and Electron fields; hold/release Fn for ordinary dictation; switch windows/fields during a request; try multiple displays. Compare suggestion usefulness, complete request latency and battery impact. Permission enable/revoke, physical shortcuts, full coordinator behavior, multi-display behavior and real-world energy use remain unverified.
