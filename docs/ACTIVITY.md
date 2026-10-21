# Activity reports

Activity reads aggregate counts from Jot's retained local history. It does not change capture or history. Deleted rows disappear from later reports; these are not lifetime counters. The separate [usage counters](#usage-counters) are the exception: text-free counts kept as events happen, which history deletion leaves in place. Ambient totals describe recorded conversation, which can include other people. They are not a measurement of your own speaking.

Use the read-only MCP tool `activity_report` with optional `days: 7` (default) or `days: 30`. Its local socket method is `activity.report` with the same arguments. Other values, booleans, fractional numbers, and unknown arguments are rejected. CLI equivalents return the report as JSON:

```sh
jot activity
jot activity --days 30
```

The report contains `schemaVersion`, `generatedAt`, `windowStart`, `windowEnd`, `days`, `timeZoneIdentifier`, separate `dictation` and `ambient` summaries, `verifiedDictationDeliveries`, `counters`, `daily`, and `measurementNotes`. Each daily bucket carries its own `counters`. Daily buckets are ordered oldest first and include zero-activity days. Dates are ISO 8601 timestamps at local midnight. The window includes today and ends at `generatedAt`; today is partial. Calendar arithmetic preserves local days across daylight-saving transitions, so a day may be 23 or 25 hours.

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

## Usage counters

`counters` maps a counter name to how many times it happened in the window; each daily bucket has the same map for its day, and names with no count are left out. Unlike everything above, counters are not derived from retained history. Jot adds to them as events happen, in a `usage_counters` table (local day, name, count) in the same transcript database, so deleting history, sessions or saved dictations does not change them. Days older than 400 are pruned. A day is the Mac's local date when the event was counted. Counting began with the build that added the table, so earlier days read zero.

Names come only from fixed codes in `UsageCounter` (`Sources/JotCore/UsageCounter.swift`); no text, app, field or session identity can be stored. Nothing is sent anywhere.

| Name | Counted when |
| --- | --- |
| `dictation.<outcome>` | A released hold ends: `completed`, `noSpeech`, `fillerOnly`, `cancelled`, `failed` or `deliveryUnverified`. Together they count every hold. |
| `insertion.<path>` | A hold's text is delivered: verified by `accessibility`, `unicode` (typed) or `clipboard`, or `unverified`, or `failed` (delivery threw). |
| `cleanup.dictation.<outcome>` | Dictation cleanup returns, by `CleanupResult.Outcome` (`changed`, `unchanged`, `timedOut`, `unavailable` and so on). |
| `cleanup.live.applied`, `cleanup.live.bypassed` | A live phrase's cleanup finished: cleaned text was saved, or the phrase stayed as recognized (busy queue, unchanged, setting turned off, session deleted). |
| `savedDictation.reviewed`, `savedDictation.copied` | Review saved dictation showed a saved hold; its text was copied. |
| `suggestion.requested` | A suggestion request began. |
| `suggestion.outcome.<outcome>`, `suggestion.action.<action>` | A suggestion request finished, once each, by its final `SuggestionHistoryEntry` outcome and, when one ended it, its action. |

To start the counters over, use **Reset counters** on the Activity screen's "How dictation went" card, or:

```sh
jot activity --reset-counters
```

Its socket method is `usage.reset`, with no arguments. It deletes every count and leaves saved history unchanged.

## Activity screen

Live resource and pipeline statistics lead the screen. CPU and memory line charts use the bounded performance samples already collected by Jot, separately from the selected 7/30-day usage window. They do not start a sampler, load transcript history, or persist new telemetry. Capture events remain available through the agent API and are not shown in Activity.

The "How dictation went" card summarizes the selected period's counters: holds, verified and unverified insertions, dictation cleanup changes, saved-dictation reviews and suggestions taken. The usage cards use the available window width, pairing related cards in wide layouts and stacking them in narrow layouts.

Activity refreshes on entry, on return to the active app, and when the selected period changes. While that tab remains active, charts refresh once a minute and aggregate history refreshes every five minutes. Leaving the tab or making the app inactive cancels those refresh loops. Diagnostic logging is independent of the tab and retains at most one sample per minute; paused service housekeeping runs once a minute. Permission and Apple Intelligence availability checks also run once a minute, with immediate revalidation when Jot becomes active and live checks at the relevant request paths. Models remain loaded and the shortcut remains event-driven for immediate held dictation.
