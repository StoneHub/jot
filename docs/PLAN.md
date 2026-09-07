# Accepted implementation

Build a native Swift app/service with FluidAudio recognition and Sortformer (four speakers). Do not compare alternative recognizers or diarizers unless the first implementation's quality warrants it.

Parallel streams: Fn press/release with focused-field insertion; local audio pipeline and agent interface. Keep raw audio in a bounded temporary memory buffer; retain searchable transcripts. Speaker IDs are session-scoped with manual names, not enrolled identities.

Ship resource statistics in the native app, CLI, and MCP. Verify microphone permissions, installation, inference, and source backup separately. CLI/MCP use one per-user local service, with no TCP/localhost server.

Finish with a private GitHub PR, a checked installed Mac build, and an honest account of live tests and remaining user permission gates. Preserve original scope through dependency fixes.
