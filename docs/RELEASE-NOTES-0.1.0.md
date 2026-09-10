# Jot 0.1.0 — release candidate notes

This version is not published yet. Public distribution is pending notarization and Gatekeeper verification.

Jot brings local dictation to your Mac: hold Fn or a custom shortcut, speak, and release to insert text without sending it.

- Personal vocabulary corrects preferred spellings before insertion.
- Built-in speakers mute while dictating and restore afterward. Other outputs are left alone; media continues playing silently. Disable this in Tuning if desired.
- Ambient capture keeps searchable local transcripts with session speaker labels.
- Named meetings export to Markdown; sessions can be renamed, read, and deleted.
- The bundled CLI and MCP server expose transcript retrieval, session controls, and bounded diagnostics.

Requires Apple Silicon and macOS 14 or later. Microphone and Accessibility permission are required for dictation. Initial speech-model downloads require internet; models are not included in the app download. Transcription runs locally. Audio is held in bounded memory rather than saved as recordings; transcript text stays on the Mac unless you export it or retrieve it through an agent connection. No UI feedback tool is included.

Speaker labels are per-session and do not identify people across sessions. Dictation is limited to 60 seconds per hold. Application Accessibility support affects text insertion. Muting does not pause playback. Force-quitting during dictation may leave the speakers muted; use the system mute control to restore them.
