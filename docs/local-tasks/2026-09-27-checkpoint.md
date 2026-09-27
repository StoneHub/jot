# Checkpoint, September 27, 2026

Where the September 27 Mac session stopped. Usage ran out mid-work; nothing is lost.

## Merged and installed

`main` at 0391c40 is installed (Release) and running. History, settings and preferences were checked after each install.

- `aaedece`: the recovery harness resets tuning after the Live reload checks. Since #115, a new service reads settings at init, so an earlier check's `speakerConfidence = 0.8` leaked into the Regroup check.
- #118: naming a speaker remembers the voice (no checkbox). Names typed before the speaker pass move with their voice onto the pass's speakers. Reviewed; the review fixes are in the same PR.
- #119: stale-screen fixes from the #112 audit. Covers the Update button after Pause or a relabel, the Sessions reader after `jot settings set paragraphPause`, the file diagnostic, a dictation discarded mid-insert, and the recovery window choices.
- #131 (another session): a newer database is refused instead of deleted; double-tap Fn says why there's no suggestion.
- #120: the draft copy check judges where a rewrite's words come from, and withheld results keep "Use meeting".

## In progress (pushed as WIP branches, not merged)

- `claude/heard-speech-rewrite`: a selection rewrite uses recent speech Jot heard that shares distinctive words with the selection. Setting `suggestionHeardMatches` is on by default, and the card says so. A real-model probe restored a missing word in 4 of 4 runs when the heard sentence was a source.
  - WIP at `408b7c3`. It builds, and its 13 new tests pass.
  - The probe results:
    - Only the matching sentences are sent. Neighbouring rows were being appended to the draft.
    - The prompt keeps the user's own words.
  - Left to do:
    - Run the full `swift test` and `local-pr-check --all`.
    - Run the fixture check and the draft evaluation after the change; the before run is done.
    - Add a docs note, merge `origin/main`, then open the PR.
- `claude/claude-code-context`: the official Claude Code plugin (Monroe's decision; not MCP, not reading ~/.claude files).
  - The plugin is at `integrations/claude-code/jot-context`, with a marketplace at the repo root.
  - The `UserPromptSubmit` and `Stop` hooks run `jot claude-context`, which sends `conversation.update` to Jot.
  - Jot keeps the conversation in memory only and uses it as a suggestion source in Claude.
  - Hooks must print nothing and exit 0. The `Stop` input has no reply text, so the CLI reads the tail of `transcript_path`.
  - Each assistant block is its own JSONL line, and `tool_result` user lines are not prompts.
- A separate session is fixing recognition errors on final chunks under 300 ms: the speech model rejects them, and the words in them are lost. 9 such events since September 26.

To finish either WIP branch: check it out, get `python3 scripts/local-pr-check.py --current --all` green, open the PR, review, merge, then install with `python3 scripts/build-install.py --configuration Release` (pause Jot first, resume after).

## Monroe's test list (bundle for one sitting)

Already confirmed:
- #110
- `jot status` after launch shows `paused`/`not loaded`, and after Pause `paused`/`unloaded`
- End meeting includes the last words (both meetings)
- Pausing keeps the speech
- `lastTranscriptAt`
- Settings carry over and survive relaunch
- The `jot settings` set/reset/refusal checks
- `jot since` returns a cursor

Still for Monroe:
- **#118 names:**
  - Name a speaker in Live during a meeting. After the pass, the name stays on the same voice and People lists them.
  - Name one in Sessions after the pass: there's no checkbox, and People lists them.
  - For the September 26 "test" session, click Bennen and "other DND member" and Save to remember those voices.
- **#112 screens:**
  - Sessions after an end, a rename, a delete and a Regroup
  - Dictations after an Fn dictation, a delete and Clear
  - The microphone list when a mic is plugged in
  - The menu bar's last line
  - Activity → Capture events and Queued audio
- **#113/#114:** `dictation` while holding Fn; the sidebar status and menu icon match; the Update button re-enables after Resume and Pause (#119).
- **#116:** General shows the sliders; `jot settings set paragraphPause 2` moves the slider and regroups Live, including the Sessions reader (#119). Restore with `set paragraphPause 0.8`, not `reset`.
- **September 26 items:**
  - #60: 10 Fn dictations, then `jot diagnostics`
  - #75: Regroup right after a session ends
  - #71: delete, Regroup, rename and search
  - #41: `jot since` during a session
- **Later:** CPU and quiet-room measurements, once Jot is feature complete (Monroe's call).
- **Once the plugin lands:** in Claude Code, `/plugin marketplace add StoneHub/jot`, then `/plugin install jot-context@jot`. Then double-tap Fn in the Claude composer and check the card says it used the conversation.
