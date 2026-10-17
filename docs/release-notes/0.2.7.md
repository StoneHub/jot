# Jot 0.2.7

Personal development checkpoint for Apple silicon Macs running macOS 14 or later. Apple Intelligence is required for on-device writing suggestions.

- Double-tap Fn requests a suggestion; Tab accepts it. Field drafts, cursor continuation, visible context and matching local agent conversations feed the request.
- Matching conversations and your own words rank ahead of unrelated room speech when context is bounded.
- Jot learns your voice from Fn dictation holds after the speaker pass, keeps the voice locally across database rebuilds, and offers Forget in People.
- Pause stops continuous listening and keeps models ready. Holding Fn while paused records only for that hold; Unload Models releases their memory.
- A directory lock prevents a second Jot instance from opening the same history. Live view, settings and performance improvements are included since 0.2.6.

Mac validation: 323 Swift tests, 48 Python tests, signed app builds, recovery checks and real speech-model recovery passed. Both 27-scenario synthetic suggestion runs completed. Generation quality remains experimental: the phone-call/Slack scenario abstained with app context settings. See docs/evaluation/contextual-suggestions/results/2026-09-28-release-checkpoint/README.md for exact results and limits.

Development-signed prerelease, not notarized. Signed by the same owner team as prior personal releases. For an existing owner-signed Jot, pause capture, open Models & updates, check for updates and install 0.2.7. Otherwise quit Jot and replace /Applications/Jot.app with the app from the ZIP on a Mac that trusts this development certificate. Models download separately; private transcripts, audio and credentials are not included.

Test when you sit down: verify existing Sessions remain; hold Fn and dictate into a field; try double-Fn then Tab without sending; switch between two agent conversations; after at least 20 seconds of Fn speech and a completed speaker pass, check People for You. This release has not been run on the work Mac yet.
