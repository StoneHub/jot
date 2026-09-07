# Accepted implementation

Build a native Swift app/service with FluidAudio recognition and Sortformer (four speakers). Do not compare alternative recognizers or diarizers unless the first implementation's quality warrants it.

Parallel streams: Fn press/release with focused-field insertion; local audio pipeline and agent interface. Keep raw audio in a bounded temporary memory buffer; retain searchable transcripts. Speaker IDs are session-scoped with manual names, not enrolled identities.

Ship resource statistics in the native app, CLI, and MCP. Verify microphone permissions, installation, inference, and source backup separately. CLI/MCP use one per-user local service, with no TCP/localhost server.

Finish with a GitHub PR, a checked installed Mac build, and an honest account of live tests and remaining user permission gates. Preserve original scope through dependency fixes.

## Native UX revision

Use one reusable Jot window with a Dock icon while it is open and a menu-bar Open action. Native history, search, activity, and model details belong in that window; no separate dashboard. Transcript rows copy their text when clicked.

Use Apple's Liquid Glass controls on macOS 26 and native material fallbacks on earlier supported macOS. Remove the marketing title and accelerator-policy footer.

Pause suspends Fn and ambient capture, discards unfinished audio, blocks late delivery, releases model references after active prediction returns, and reduces the idle timer frequency. Preserve separate Fn/ambient selections for Resume. Turning ambient off alone keeps Fn available. Model checks are manual and do not claim an unversioned installed cache matches upstream publications.
