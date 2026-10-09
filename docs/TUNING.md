# Tune together

Balanced now uses a 1.5-second paragraph pause and a 1.2-second minimum speaker turn, keeping confidence at 0.65. Existing saved settings are preserved; choose Balanced to try the new values.

Dictations now folds unfinished-sentence continuations just like session exports, including up to 100 ms of timestamp overlap. Raw SQLite rows and MCP recent/search results remain unchanged; use MCP session export for readable conversation context. Brief uncertainty under two seconds can retain the preceding speaker during new capture; sustained uncertainty remains unattributed. This is a continuity heuristic, not verified speaker identity.

Open **General → Speakers & paragraphs** in the native app. Each setting's (i) explains it. Start with Balanced, or use Steadier speakers when brief hesitations cause extra speaker turns.

| Control | Effect | Tradeoff |
| --- | --- | --- |
| Speaker confidence | Requires a stronger speaker score | Higher values can leave more speech unknown |
| Minimum speaker turn | Requires sustained evidence before changing the current speaker | Short real replies can stay with the preceding speaker |
| (built in) | A reply of 0.3 s or more whose voice the diarizer is sure about (0.85 or higher, nobody else above the confidence setting) switches speaker regardless of the minimum turn | A quiet or mumbled short reply still merges |
| Paragraph pause | Groups nearby words and same-speaker rows | Longer values create fewer, longer rows; live recognition still submits short chunks |
| Hide filler-only rows | Hides isolated um/uh/hmm rows in Dictations | Original text remains in SQLite and CLI/MCP; fillers within sentences remain visible |

Speaker settings apply to new audio and to any session you regroup. Dictations presentation changes immediately for paragraph grouping and filler visibility. This does not rerun old audio: recordings are not retained. Source words are not rewritten or deleted. Settings persist and are reported by `jot status` / MCP status.

## Regroup a saved session

Jot keeps each ambient row's words with their timings and speaker probabilities. **Regroup** in Sessions runs the current speaker settings over those words and relabels the session's rows; a row whose speaker changes inside it splits there. Rows keep their cleaned text, and speaker names, the title, and capture events stay. Right after a session ends, Regroup waits for its last phrase to be cleaned before it changes any row. A session recorded before words were kept cannot be regrouped, and a session that is still recording must be stopped first.

## Compare settings with jot lab

`jot lab` runs a recording through the real pipeline once per settings variant and compares the results. That covers capture chunking, recognition, live speakers, cleanup and the speaker pass. It runs in its own process with its own settings and a temporary store, so Jot keeps listening and history and preferences are untouched.

```
jot lab debate.wav --variants variants.json --out ~/Documents/jot-lab/debate-1 --captions debate.srt
```

`variants.json` lists named variants. Each one changes settings from Jot's current values, using the keys `jot settings` lists:

```json
[
  {"name": "current", "settings": {}},
  {"name": "steadier speakers", "settings": {"minimumSpeakerTurn": 2.0, "paragraphPause": 2.0}},
  {"name": "no cleanup", "settings": {"cleanUpTranscriptions": false}}
]
```

- Grouping settings (`speakerConfidence`, `minimumSpeakerTurn`, `paragraphPause`) reuse one recognition run. That run records under your current grouping, and each variant then regroups the stored words, the same way Regroup does in Sessions.
- Capture, recognition and cleanup settings each need their own run. Cleanup gets its own run too, so phrases are assembled exactly as they are live. Settings that don't change transcription are refused.
- The speaker pass runs once per recording.
- `--captions` takes SubRip (`.srt`) or WebVTT (`.vtt`). Each variant gets a word error rate for its recognized words and for its cleaned text.
- When the captions name speakers with voice tags (`<v Kim>`), each variant also gets two speaker scores, one for its live speakers and one for the speaker pass:
  - **Speaker words right**: the share of recognized words whose speaker matches the captions. Each speaker id is paired with at most one caption voice, the pairing that gets the most words right, so a voice split across two ids counts once. Words in a row with no speaker count as wrong, even where Sessions shows that row under the speaker before it. Words between cues, or in a cue without a voice tag, aren't scored.
  - **DER**: the diarization error rate of the stored rows, split into missed speech, false alarm and confusion, ignoring 0.25 s each side of every cue boundary. Time between rows counts as missed speech and row time outside every cue as false alarm, so confusion is the part that measures who was named. It needs every cue to name a speaker.

The output folder must be new and outside any git repository: the recording's transcript is private. It holds two files:
- `variants.json`: each variant's stored rows (times, live speaker, pass speaker, raw and cleaned text, cleanup outcome), its paragraphs as Sessions shows them, its timings and its score.
- `report.html`: the variants side by side.

Limits:
- The lab feeds audio as fast as recognition and cleanup keep up, so it never shows the cleanup skips a busy Mac can produce live.
- It shares the Neural Engine and the on-device cleanup model with Jot. While a lab runs, live recognition can fall behind and live phrases can go uncleaned.
- YouTube's auto-generated captions repeat each line in the next cue, and the lab hasn't been checked against one yet. Use uploaded captions or a hand-made SRT.

A row with no cleaned text was left alone by cleanup. That covers cleanup off or failing, and also cleanup returning the words unchanged, which Jot doesn't save. The run's phrase outcomes in the report tell these apart.

Apply the variant you choose with `jot settings import variants.json "steadier speakers"`. It sets each of that variant's settings on the running app, as `jot settings set` would.

## A short comparison

1. Choose 30–60 seconds with a clear speaker change and a hesitation. Keep microphone position, playback volume, and source fixed.
2. Enable the player's English captions and note its playback time. Resume Jot for that passage, then Pause to stop listening and finish saving it.
3. Separately judge missed/wrong words, unnecessary speaker changes, and annoying paragraph breaks. Do not count every caption omission of a filler as an ASR mistake.
4. Change one control and replay the same passage. If genuine short replies merge into the preceding speaker, lower Minimum speaker turn. If rows are merely too short, increase Paragraph pause.
5. Pause the service when done. Unload Models in the menu frees the models' memory if you need it back. No automatic tuning or reference-text injection is performed.

## Heretic reference

For the 2024 A24 film:

- [Official A24 screenplay](https://a24awards.com/assets/Heretic-screenplay.pdf). The dialogue observed near the user's roughly 27-minute checkpoint matches script page 19 (PDF page 20). This is a content match, not exact timecode alignment. The screenplay is a draft reference and may differ from the finished film.
- [Correct Apple TV listing](https://tv.apple.com/us/movie/heretic/umc.cmc.4w5pkhqxkzn3nclhayej0fxvh) identifies A24, 2024, and English CC. The playback service was not specified, so no specific caption track was downloaded or synchronized.

Use actual playback captions for wording/timing and human judgment for speaker continuity. No movie text/audio is stored in this repository and no accuracy score has been fabricated from the reference.
