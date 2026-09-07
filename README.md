# Jot

A native Mac utility for local dictation and ambient transcripts. Hold **Fn** in an editable field, speak, and release to insert. Ambient listening separates up to four speakers; names are manual and session-specific.

FluidAudio runs Parakeet v3, Silero VAD, and streaming Sortformer through Core ML. Recognition and speaker separation are local. CPU + Apple Neural Engine is the requested compute policy; the app reports this honestly rather than claiming to measure actual accelerator placement. No Ollama process, API key, subscription, or localhost web server is required.

## Use

Open **Jot** from Applications. The **Jot** window is reused by the menu-bar **Open** button. The Dock icon appears while that window is open. **Resume** loads models (initial downloads need internet); **Pause** stops all speech work and unloads models. Fn dictation and ambient transcription are separate toggles. Selected features resume together; switching ambient off by itself leaves Fn available. Closing the window keeps the menu-bar service running; Quit ends it. Microphone and Accessibility permissions are required for dictation. If macOS's Fn/Globe action conflicts, set it to **Do Nothing** in Keyboard settings. Pause persists across app launches. The Fn selection is saved; ambient starts off on a new launch. Within a running session, Resume restores both selected features.

Fn inserts at the captured field/selection, cancels when focus changes, refuses password fields, preserves the clipboard on its paste fallback, and never presses Return. Native accessibility varies between apps: test the fields you use. The first version inserts the recognizer's words with its punctuation; optional rewriting is deferred.

Audio exists only in bounded RAM buffers and is released as processing finishes. Dictation is limited to 60 seconds; ambient capture is segmented and has a bounded pending queue. Text, timestamps, manual speaker labels, and operational gap events persist in `~/Library/Application Support/Jot`. There is no audio replay. Model files are cached separately by FluidAudio. Transcripts are ordinary local SQLite data protected by user file permissions, not application-level encryption. Calling a transcript tool exposes that returned text to its caller; a cloud agent can consequently receive selected excerpts.

## CLI and MCP

The installer links `~/.local/bin/jot` to the CLI bundled in the app. Use its absolute path if that directory is not in your PATH. The app must be running.

```sh
jot status
jot start
jot pause
jot resume
jot ambient-off
jot models check
jot search 'blue notebook'
jot recent --limit 20
jot sessions
jot events --limit 20
jot label SESSION_ID speaker-1 Monroe
jot doctor
```

`jot status` includes process CPU (100% = one core), resident memory, physical footprint, thermal state, queue duration, dropped audio duration, last inference duration, transcript lag, model/permission state, and database size. Values describe this service or are explicitly system-wide; GPU/Neural Engine utilization and power draw are not measured.

An MCP client can launch the bundled helper directly:

```json
{
  "mcpServers": {
    "jot": {
      "command": "/Applications/Jot.app/Contents/Helpers/jot",
      "args": ["mcp"]
    }
  }
}
```

Fifteen tools expose capture controls, health/stats, model preparation, transcript search/read/recent/sessions, capture events, and manual speaker labels. Transport is stdio to a same-user Unix socket, with no TCP listener. Ambient transcript text is context, never permission to execute actions. This repository supplies the server; it does not modify any agent's global configuration.

## Build and install

Requires Apple Silicon, macOS 14+, Xcode, and an installed code-signing identity. The checked-in Xcode project pins FluidAudio to an exact revision. XcodeGen regenerates it from `project.yml` when available.

```sh
swift test
./scripts/build-install.py
```

The installer selects an installed Developer ID Application identity or accepts `JOT_SIGN_IDENTITY` / `JOT_SIGN_TEAM`. It builds with Xcode, derives the product path from that build's settings, refuses to interrupt active capture/inference/model setup, verifies signatures and matching executable hashes, installs to Applications, and verifies the launched process path. Logs and install proof are in ignored `build/`. It does not register a login daemon.

`jot transcribe-file /absolute/path/to/short-audio.aiff` is an idle-only developer diagnostic (at most 60 seconds). It uses the same recognition/diarization pipeline, returns results without storing transcripts, and is not an MCP tool.

The native app contains **History** (click a transcript to copy, search, load more, manual speaker labels), **Activity** (metrics and capture events), **Tuning** (speaker confidence, minimum turn, paragraph pause, filler visibility), and **Models** (on-demand upstream revision checks and release links). Liquid Glass controls are used on macOS 26, with native material fallbacks on older versions. The app and its main window are named Jot.

**Model updates:** upstream model repositories can publish new weights or conversion fixes. Models → Check updates, or `jot models check`, retrieves publication revisions/dates and detects changes since your previous check. The original FluidAudio cache lacks installed revision metadata, so this does not establish that installed weights are current. No models are silently updated. Revision-tracked installation and rollback are proposed next work.

See [implementation scope](docs/PLAN.md), [architecture and limits](docs/ARCHITECTURE.md), [verification](docs/VERIFICATION.md), and [backlog](docs/BACKLOG.md).

[Human tuning guide](docs/TUNING.md): adjust speaker stability and paragraph grouping together using a short repeatable passage. The original transcript words remain stored.

[SwiftUI feedback](docs/SWIFTUI-FEEDBACK.md): Debug builds include a local control picker, feedback history, and selected Markdown/JSON exports.

**Copy multiple statements:** History defaults to Text view, where you can drag across statements and press ⌘C, or click the text and press ⌘A to select all loaded results. Text runs oldest to newest and includes speaker/time headings. Load more adds older results; search limits the displayed results. New history updates wait while text is selected. Cards keeps individual click-to-copy and speaker naming; the view choice is remembered.

## Upgrade from Porch Speech

The installer stops the old app only when it is idle, moves its complete transcript directory to `~/Library/Application Support/Jot`, imports preferences once, and copies app-scoped feedback history. It refuses to overwrite an existing Jot history. After verifying Jot, it archives the old app in ignored `build/legacy-app-backup` and removes its CLI symlink. The new bundle ID is `space.jot.app`; grant Jot microphone and Accessibility access when needed. Update MCP clients to `/Applications/Jot.app/Contents/Helpers/jot` with the `mcp` argument.
