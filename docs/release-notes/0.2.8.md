# Jot 0.2.8

Separate suggestions from saved dictation. Double-Fn only requests suggestions; when suggestions are off, it never inserts recent room speech. Review saved dictation explicitly to preview and copy an undelivered hold, including while paused. The old Recovery window setting and automatic fallback are removed.

Apple Intelligence remains optional. Suggestions explain unavailable states, cleanup preserves recognized text when unavailable, and previously enabled unavailable features can be switched off.

Development prerelease, signed with the local Apple Development identity; not notarized. Requires a Mac that trusts this development certificate. Basic app support starts at macOS 14; Apple Intelligence enhancements require compatible hardware and macOS 26 or later. Transcripts and audio stay on the Mac. Models download separately.

Validation: 323 Swift tests, 48 Python tests, signed Release build, recovery-controller checks with real-model synthetic audio, and all simulated model-unavailability states. Older-OS hardware and physical Fn/Tab acceptance remain user checks.
