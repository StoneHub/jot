# Jot

Jot is a Mac utility for local dictation and ambient transcription. Hold **Fn**, speak, and release to insert text into the focused field. Turn on ambient transcription to capture conversations, with up to four speaker labels you can name per session.

Requires Apple Silicon and macOS 14 or later. Speech recognition runs locally through [FluidAudio](https://github.com/FluidInference/FluidAudio). The first model download needs internet.

## Use

Open **Jot** from Applications and grant microphone and Accessibility access. If Fn triggers a macOS shortcut, set the Fn/Globe action to **Do Nothing** in Keyboard settings.

- **Resume** loads models and enables your selected speech features. **Pause** stops speech processing and unloads models.
- **Fn dictation** and **Ambient transcription** have separate switches. Ambient starts off when you launch Jot.
- Closing the window keeps Jot in the menu bar. **Open** brings the window back; **Quit** stops the app.

Dictation supports up to 60 seconds per hold. It cancels if focus changes, skips password fields, and never presses Return. Text insertion depends on the target app's Accessibility support.

In **History**, search transcripts, select text across statements, and press ⌘C to copy. **Load more** adds older results. Cards view supports individual copying and speaker naming. **Activity** shows resource use, capture events, and whole-Mac battery loss during observed battery-powered periods since Jot launched. Battery figures include other apps and reset when Jot quits. **Tuning** adjusts speaker grouping and paragraph breaks; see the [tuning guide](docs/TUNING.md).

**Models → Check updates** checks published model revisions. It does not download updates or verify that your cached weights match the latest release.

## Data and privacy

Audio stays in temporary memory buffers and is discarded after processing. Jot saves text, timestamps, speaker labels, and capture events in `~/Library/Application Support/Jot`. It does not save recordings for replay.

Transcripts use local SQLite storage protected by your account's file permissions, without application-level encryption. Model files are cached separately. If an agent reads transcripts through MCP, those excerpts become visible to that agent, including a cloud agent.

## CLI and MCP

The installer adds `~/.local/bin/jot`. Jot must be running to use it.

```sh
jot status
jot pause
jot resume
jot start                 # Start ambient transcription
jot ambient-off
jot search 'blue notebook'
jot recent --limit 20
jot doctor
jot --help
```

`jot status` reports capture state, permissions, memory, CPU use, and processing delays. It does not measure GPU or Neural Engine utilization.

Add this to your MCP client's configuration:

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

The server exposes capture controls, status, model preparation, transcript search and reading, sessions, events, and speaker labels. It uses stdio and a same-user Unix socket. Transcript content is context, not permission for an agent to act.

## Build and install

Requires Xcode and an installed Developer ID Application signing identity. The project pins FluidAudio to an exact revision. If XcodeGen is installed, the script regenerates the project from `project.yml`.

```sh
swift test
./scripts/build-install.py
```

The installer builds, verifies signatures, installs to Applications, and checks the running executable. It refuses to replace the app during capture, inference, or model preparation. Set `JOT_SIGN_IDENTITY` and `JOT_SIGN_TEAM` to override signing defaults. Build logs and installation proof are in `build/`.

See [architecture and limits](docs/ARCHITECTURE.md), [verification](docs/VERIFICATION.md), and [planned work](docs/BACKLOG.md). Debug builds also include [local UI feedback tools](docs/SWIFTUI-FEEDBACK.md).
