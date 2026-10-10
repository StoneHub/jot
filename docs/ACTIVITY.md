# Activity reports

Activity reads aggregate counts from Jot's retained local history. It does not change capture or history. Deleted rows disappear from later reports; these are not lifetime counters. Ambient totals describe recorded conversation, which can include other people. They are not a measurement of your own speaking.

Use the read-only MCP tool `activity_report` with optional `days: 7` (default) or `days: 30`. Its local socket method is `activity.report` with the same arguments. Other values, booleans, fractional numbers, and unknown arguments are rejected. CLI equivalents return the report as JSON:

```sh
jot activity
jot activity --days 30
```

The report contains `schemaVersion`, `generatedAt`, `windowStart`, `windowEnd`, `days`, `timeZoneIdentifier`, separate `dictation` and `ambient` summaries, `verifiedDictationDeliveries`, `daily`, and `measurementNotes`. Daily buckets are ordered oldest first and include zero-activity days. Dates are ISO 8601 timestamps at local midnight. The window includes today and ends at `generatedAt`; today is partial. Calendar arithmetic preserves local days across daylight-saving transitions, so a day may be 23 or 25 hours.

Each mode summary contains:

| Field | Meaning |
| --- | --- |
| `wordCount` | Approximate saved-text words: whitespace-separated units containing a letter or number. Latest cleaned text takes precedence over recognized text. Punctuation-only units are excluded. This is not a language-aware tokenizer or acoustic word count. |
| `timedWordCount` | Words from rows with positive measured window duration. Zero-duration rows still contribute to `wordCount`. |
| `segmentCount` | Number of retained transcript rows, which can change after regrouping. |
| `sessionCount` | Distinct retained session identifiers for that mode within the window. Session identifiers are not returned. Dictation can share an ambient session; this field is not a dictation-attempt count. Daily session counts can repeat across days and must not be added to obtain the report's distinct total. |
| `speechWindowSeconds` | Sum of retained row windows, clipped at the report end. Dictation windows represent held dictation; ambient windows represent transcription segments. Both can contain pauses and overlapping speech. This is not voiced duration, microphone uptime, battery use, or time saved. |
| `activeDays` | Number of local days with at least one saved row in that mode, including zero-duration rows. |
| `hasCompleteTiming` | False when an included row has an end beyond the report end or a nonfinite end. |
| `wordsPerMinute` | `timedWordCount × 60 / speechWindowSeconds`, a rate across recorded windows including pauses. Explicit JSON `null` when duration is zero or timing is incomplete; full text cannot be apportioned across partial time. |

Rows are included and assigned to a bucket by absolute start time (`startedAt + startSeconds`). Rows that begin before `windowStart` or after `windowEnd` are excluded. A window crossing midnight belongs wholly to its start day; its duration is clipped only at the report end. Dictation and ambient are separate views of saved speech and can overlap: do not add their word or duration totals to estimate unique speech.

`verifiedDictationDeliveries` counts retained attempt records currently in the `delivered` state, grouped by their latest successful verification timestamp (`updatedAt`). Retrying the same attempt can move its bucket, but does not create another count. Unverified, failed, recognizing, ready, and discarded records do not count. Delivery records were added after transcript history, so older saved dictations may have none. Deleting attempts/history removes their evidence. The count is not every hold, every insertion attempt, or proof that all dictation rows reached a target field.

The payload contains no transcript text, audio, speaker names, session identifiers, or app identities. `measurementNotes` travels with the data so agents can preserve these limitations when creating charts. No typing-speed baseline or time-saved estimate is invented.

For Mac impact charts, pair this report with the read-only `speech_status` resource snapshot and `speech_diagnostics` bounded local performance diagnostics. Those describe the current runtime and retained diagnostic samples, not resource totals for the 7/30-day history window. Jot does not retain historical battery or CPU usage alongside these activity buckets. Keep their sampling interval and scope visible when charting them together.
