# Tune together

Open **Tuning** in the native app. Start with Balanced, or use Steadier speakers when brief hesitations cause extra speaker turns.

| Control | Effect | Tradeoff |
| --- | --- | --- |
| Speaker confidence | Requires a stronger speaker score | Higher values can leave more speech unknown |
| Minimum speaker turn | Requires sustained evidence before changing the current speaker | Short real replies can stay with the preceding speaker |
| Pause between paragraphs | Groups nearby words and same-speaker rows | Longer values create fewer, longer rows and can delay ambient results |
| Hide filler-only rows | Hides isolated um/uh/hmm rows in history | Original text remains in SQLite and CLI/MCP; fillers within sentences remain visible |

Speaker settings apply to new audio. History presentation changes immediately for paragraph grouping and filler visibility. This does not rerun old audio: recordings are not retained. Source words are not rewritten or deleted. Settings persist and are reported by `jot status` / MCP status.

## A short comparison

1. Choose 30–60 seconds with a clear speaker change and a hesitation. Keep microphone position, playback volume, and source fixed.
2. Enable the player's English captions and note its playback time. Resume ambient transcription for that passage, then switch ambient off to finish its final segment.
3. Separately judge missed/wrong words, unnecessary speaker changes, and annoying paragraph breaks. Do not count every caption omission of a filler as an ASR mistake.
4. Change one control and replay the same passage. If genuine short replies merge into the preceding speaker, lower Minimum speaker turn. If rows are merely too short, increase Pause between paragraphs.
5. Pause the service when done to unload models. No automatic tuning or reference-text injection is performed.

## Heretic reference

For the 2024 A24 film:

- [Official A24 screenplay](https://a24awards.com/assets/Heretic-screenplay.pdf). The dialogue observed near the user's roughly 27-minute checkpoint matches script page 19 (PDF page 20). This is a content match, not exact timecode alignment. The screenplay is a draft reference and may differ from the finished film.
- [Correct Apple TV listing](https://tv.apple.com/us/movie/heretic/umc.cmc.4w5pkhqxkzn3nclhayej0fxvh) identifies A24, 2024, and English CC. The playback service was not specified, so no specific caption track was downloaded or synchronized.

Use actual playback captions for wording/timing and human judgment for speaker continuity. No movie text/audio is stored in this repository and no accuracy score has been fabricated from the reference.
