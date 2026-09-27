# Mac handoff, September 27, 2026

A local agent on Monroe's Mac takes `main` from uncompiled to installed, then Monroe tests end to end. Follow [AGENTS.md](../../AGENTS.md): fix forward on `main`, preserve capture and history.

## Where things stand

`main` is at `a7d3aee` or later. The installed app is 0.2.6 (13) with a format 7 database (about 5.5k transcripts, 31 sessions).

| Merged | What | Compiled? |
|---|---|---|
| #100–#109 | Diagnostics, `transcripts.since`, database format 8, Regroup ordering, incremental rows, quiet-audio CPU, legacy deletion (see the September 26 handoff in the PRs) | Yes, each passed `local-pr-check` |
| #110 | The window resizes to 520 × 420 without clipping; below 720 points wide the sidebar becomes an icon rail | **No** |
| #112 | #61: Host protocols, forwarders and the redraw relay are gone; screens observe the objects they show | **No** |
| #113 | #62 part 1: the recognition worker moves into `Transcriber` | **No** |
| #114 | #62 part 2: `ListeningState` derives `mode` and the model state | **No** |
| #115 | #58 part 1: `JotSettings`, one key per setting; the tuning blob carries over once; `jot settings` | **No** |
| #116 | #58 part 2: chunk, silence, speech-gate, phrase and cleanup values become live settings | **No** |

The six uncompiled PRs were written and reviewed in a Linux cloud session. Expect compile errors; each PR description lists what it changed and what to test.

## 1. Build `main` and fix forward

1. Update the canonical checkout to `origin/main`. Leave Jot running and paused; do not start or stop capture.
2. Run `python3 scripts/local-pr-check.py --current --all`. On `main`, `--all` is required: without it the diff against `main` is empty and only the portable gates run.
3. Fix compile or test failures with the smallest change, commit to `main`, and run the check again until it passes. Likely spots:
   - Memberwise initializer order for `LiveView(service:library:timeline:)`, `SessionsView(service:library:timeline:openLive:)`, `PeopleView(speakers:)` and `TranscriptView(service:library:delegate:)`.
   - `Jot.xcodeproj/project.pbxproj` entries for `Transcriber.swift`, `ListeningState.swift` and `JotSettings.swift`, which were added by hand. If `xcodegen` is installed, the build scripts regenerate the project from `project.yml`.
   - Pattern matches on `JotSettings.Definition.Kind` (labeled associated values) and the `set(_:_:)` overloads.
   - `SpeechService.preparation`'s `willSet`, and `ListeningState.Models` where `ModelState` used to be.
   - `ViewThatFits` rows in `TranscriptView+Settings.swift`, `LiveView.swift` and `SessionsView.swift`.
4. Run `JotRecoveryChecks --audio` by hand; the pipeline changed (#113, #116) and `local-pr-check` does not run the real-model path.

If a fix is not obvious after two attempts, revert that one PR's squash commit on `main`, note it on its issue, and continue with the rest.

## 2. Install

1. Export preferences first. The first launch removes the tuning blob after carrying it over, and deletes keys that hold their default:
   `defaults export space.jot.app ~/Desktop/jot-preferences-before-settings.plist`
2. With Jot paused and idle, run `python3 scripts/build-install.py --configuration Release`. The installer refuses to replace a busy app and keeps a backup of the old bundle.
3. After first launch, confirm that history is intact (the database upgrades from format 7 to 8) and that `jot settings` shows your tuning values as changed.

For a CPU problem, export `jot diagnostics` before relaunching Jot; its buffer clears on quit.

## 3. Monroe's end-to-end test

Batch these in one sitting. Report anything broken as a comment on the PR that caused it, or as a new issue.

**Window (#110):** drag to the minimum on every page; nothing is clipped. Cross 720 points wide both ways; the sidebar and rail swap, and Live keeps its feed. In the rail, Pause/Resume works and hover shows page names.

**Screens update (#112):** Live rows and chips while listening; Sessions after a session ends, a rename, a delete and a Regroup; the Dictations count and list after an Fn dictation, a delete and Clear; People after naming with "Remember this voice"; the microphone list when a mic is plugged in; the menu bar's last line; Activity → Capture events.

**Listening state (#113, #114):** `jot status` after launch shows `paused` and `not loaded`; after Resume, `ambient` and `ready`; while holding Fn, `dictation`; after Pause, `paused` and `unloaded`. The sidebar status and menu bar icon match. End meeting includes the last words. Pausing mid-speech keeps the speech. The Update button re-enables after Resume and Pause.

**Settings (#115, #116):** General shows your previous choices, including the speaker and paragraph sliders. `jot settings set paragraphPause 2` regroups Live at once and moves the slider; `jot settings reset paragraphPause` restores it. `jot settings set newSessionAfterSilence 12` is refused. Settings survive quit and relaunch. With nothing changed, quiet-room CPU matches #105's figure.

**From the September 26 handoff:**
- #60: about 10 Fn dictations, then `jot diagnostics` median and p95 latency, with and without cleanup.
- #75: end a session and press Regroup at once; the pass's speakers and names stick.
- #71: Live, Sessions and Dictations stay correct across a delete, a Regroup, a rename and a search.
- #93, #105, #107: quiet room, Live screen, cleanup off; `jot status` CPU near 1–1.5% against the issue's 5%; Activity → Queued audio still updates.
- #41: `jot since` while a session runs.

## 4. Then, locally, with a compiler

These two refactors need a compiler and measurements, so they were not done in the cloud:

- **#63** Take the store and the dictation shortcut off the main thread. Preserve write ordering, and measure the 50 ms main-thread bound on a 7k-row database.
- **#65** One type per file, one word per concept, and Swift 6 strict concurrency. Do not rename socket, CLI or MCP names; list proposed renames as a follow-up.

Also open from #58: make the speaker pass's model configuration (`SpeakerPass.swift`) a setting, checking FluidAudio's configuration API.

After that, the build order in [PLAN.md](../PLAN.md) continues with #59, the tuning lab.
