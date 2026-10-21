# Shared contract: Jot for Mac and Jot for Android

Jot for Mac (this repository) and Jot for Android ([StoneHub/jot-android](https://github.com/StoneHub/jot-android)) share no code. They share the files and rules below, so a person can move their own data between the two and both apps behave the same way on it. This document is the spec; when an app and this document disagree, fix one of them in the same change.

## Principles

- **Files, not a service.** Everything here is a local file the person makes and moves themselves: AirDrop, a USB cable, a folder they already sync. Neither app uploads it, and there is no Jot sync service or account. A future transport (for example a local network handoff) must carry these same files unchanged.
- **Every file names its format and version.** A JSON file carries `"format"` and an integer `"version"`. A reader refuses a format it does not know and a version newer than it reads, with a message that says to update the app. It never reads a newer file in part.
- **Unknown fields are ignored.** Within a version, a writer may add optional fields that an older reader can safely skip. A change that alters what an existing field means, or that an older reader must not ignore, takes a new version number.
- **Ids stay on the device.** Database and entry ids are local. Files carry content, not ids, and a reader matches by content.
- **No private data in fixtures.** Shared samples under `docs/contract/` are synthetic.

## Personal vocabulary file (`jot.vocabulary`, version 1)

Status: Mac writes and reads it (`jot vocabulary export` and `jot vocabulary import`, `VocabularyFile` in JotCore). Android imports it (Import vocabulary in the lab's Files from Jot for Mac section, `contract/VocabularyFile.kt`) and keeps its own list in the same format, with the same entry and matching rules. It does not apply the list yet, because it does not insert text yet. Sample: [`docs/contract/vocabulary-v1.json`](contract/vocabulary-v1.json), which `VocabularyFileTests` reads; Android's tests read a copy.

```json
{
  "entries" : [
    { "enabled" : true, "heard" : "", "preferred" : "SwiftUI" },
    { "enabled" : true, "heard" : "see plus plus", "preferred" : "C++" },
    { "enabled" : false, "heard" : "mon row", "preferred" : "Monroe" }
  ],
  "format" : "jot.vocabulary",
  "version" : 1
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `format` | string, required | Always `jot.vocabulary`. |
| `version` | integer, required | `1`. |
| `entries` | array, required | The list in order. Order matters (see matching). |
| `entries[].preferred` | string, required | The spelling to insert. |
| `entries[].heard` | string, optional, default `""` | The phrase recognition produces. Empty means the entry only fixes the capitalization of `preferred`. |
| `entries[].enabled` | boolean, optional, default `true` | A disabled entry is kept but not applied. |

Writers emit every field. The Mac writes UTF-8 JSON with sorted keys, two-space indents and a trailing newline; readers must not depend on layout.

### Entry rules

Both apps enforce these when saving an entry, whether typed or imported:

- `preferred` and `heard` are trimmed of leading and trailing whitespace. `preferred` must then be non-empty.
- Each field is at most 200 characters and contains no line break.
- The **matching phrase** is `heard`, or `preferred` when `heard` is empty. Two entries may not have the same matching phrase, compared ignoring case and treating any run of whitespace as one space.
- A list holds at most 1,000 entries. A file larger than 2,000,000 bytes is refused.

### Matching

How an app applies enabled entries to text it is about to insert:

- A matching phrase matches case-insensitively, with any run of whitespace between its words, only at whole-word boundaries: the characters on either side are not letters, marks, digits or `_` (Unicode categories L, M, N).
- All entries match against the original text in one pass. At the same starting position the longer match wins; at the same position and length the earlier entry in the list wins. Overlapping later matches are dropped.
- The replacement is `preferred` inserted literally. A replacement is never matched again, so entries do not chain.

On the Mac, vocabulary applies only to dictation it inserts, after spoken symbols (such as "forward slash") are turned into characters. Listening rows keep the words as spoken. Android should do the same when it gains insertion.

### Import

Import adds entries; it never changes or removes one. An entry whose matching phrase the list already has, or that an earlier entry in the same file added, is skipped. Every entry and the 1,000 entry limit are checked before anything is saved, so a bad file imports nothing. The Mac reports how many entries it added and skipped.

To replace a list rather than merge into it, remove the entries first, then import.

## Session file (`jot.session`, version 1)

Status: the Mac writes it (`jot export <session-id> --file`, MCP `transcripts_export` with `format: "session"`, `SessionFile` in JotCore). Android opens it read-only (Open session in the lab's Files from Jot for Mac section, `contract/SessionFile.kt`) and shows its rows. Android does not write session files yet, and a Mac import is not built. Sample: [`docs/contract/session-v1.json`](contract/session-v1.json), which `SessionFileTests` reads; Android's tests read a copy.

| Field | Type | Meaning |
| --- | --- | --- |
| `format` | string, required | Always `jot.session`. |
| `version` | integer, required | `1`. |
| `title` | string, optional | The session's name; absent for an untitled session. |
| `startedAt` | string, required | When the session began, ISO 8601 UTC in whole seconds. Row times count from it. |
| `rows` | array, required | Spoken rows in the order they were spoken. |
| `rows[].start`, `rows[].end` | number, required | Seconds from `startedAt`, to the millisecond. `end` is never before `start`. |
| `rows[].text` | string, required | What was said, after cleanup. Never empty. |
| `rows[].mode` | string, required | `ambient` for listening or `dictation` for a held dictation. A reader must accept other values. |
| `rows[].speaker` | string, optional | The session's own speaker grouping, such as `speaker-1`, or `overlap` when voices overlapped. It means nothing outside the session. Absent when no speaker was found. |
| `rows[].speakerName` | string, optional | The name a person gave that speaker. |

Rows are what the Mac stores, with rows that cleanup emptied left out, and an unattributed row that finishes a speaker's sentence given that speaker. They are not merged into paragraphs; a reader merges them its own way. There are no session or row ids. A dictation row is placed at the time it was spoken.

### Markdown export

The Mac writes a finished meeting to `~/Documents/Jot Sessions` as Markdown (`TranscriptExport.markdown`). This layout is what people and other tools already read, so it changes only on purpose:

```markdown
# <title, or "Session"> <yyyy-MM-dd HH:mm zone>

Session <session id>. <n> segments, <h:mm:ss> of audio, ending <yyyy-MM-dd HH:mm zone>.
Speakers without a name are Jot's automatic groupings. Timestamps are offsets from session start.

**[h:mm:ss] <Speaker>:** <paragraph text>
```

`<Speaker>` is the person's label, else `Speaker N`, `Overlap` or `Unattributed`. Paragraphs join the same speaker's rows across short pauses.

`jot export <session-id> --json` (MCP `format: "json"`) stays as it was: the socket's own rows with their ids, for agents on this Mac. It is not a file format; share the session file instead.

## Cleanup checks (`jot.cleanup-checks`, version 1)

Both apps use a small on-device model to remove filler and fix punctuation, and both keep the original text when the result looks unsafe. The checks below decide "unsafe". They are a conservative fallback that rejects known dangerous edits, not a proof that the meaning is unchanged.

Status: the Mac's `CleanupValidation` implements them, and `CleanupContractTests` runs the shared corpus [`docs/contract/cleanup-checks-v1.json`](contract/cleanup-checks-v1.json) against it. Android's `CleanupChecks` implements them too, and its `CleanupContractTest` runs a byte-identical copy of the corpus in a JVM unit test (jot-android `app/src/test/resources/contract/`). When the corpus changes here, copy it there in the same round.

A candidate is accepted only when all of these hold:

1. **Not empty.** The candidate, trimmed of whitespace and line breaks, is non-empty.
2. **Not much longer.** The trimmed candidate is at most max(120, 2 × the source's length) UTF-8 bytes.
3. **Same protected words in the same order.** Both texts are lowercased, `’` becomes `'`, and they are split at every character that is not a letter, mark, digit, `'`, `.` or `,`. Leading and trailing `.` and `,` are then stripped from each piece. A piece is protected when it contains a digit, or is one of these words:
   - Numbers: zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third half quarter percent point
   - Negations and hedges: no not never cannot can't don't doesn't didn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't hasn't hadn't maybe probably possibly might unless

   A protected word that repeats the one right before it counts once, so removing an accidental "three, three" passes. The two sequences must be equal. Spelling a number differently ("twenty five" and "25", "2.5" and "2,5") therefore rejects.

The corpus file is `{"format": "jot.cleanup-checks", "version": 1, "cases": [{"name", "source", "candidate", "accept"}]}`. Every case is synthetic. An app passes when its check returns `accept` for every case. Add a case for each bug either app's checks let through.

Where the apps still differ:

| | Mac (`JotSettings.defaultCleanupInstructions`, `CleanupValidation`) | Android (`CleanupNpu.kt`, `CleanupChecks`) |
| --- | --- | --- |
| Input | Batches of transcript entries, returned as `texts` | One dictation up to 1,200 characters |
| Control text | Not checked | Also rejects output containing `<think>` or `<|` |
| Personal vocabulary | Applied to inserted dictation | Imported and kept, not applied (Android does not insert text yet) |

Android's control text check is a good addition. Adding it to the shared rules takes version 2 of the corpus, because a Mac that ignored it would accept cases Android rejects. The prompts differ too, because their inputs differ, and they are not part of the contract. Their outputs are what the checks guard.

## Changing this contract

Add or change a rule here in the same pull request as the code. Bump a file's `version` only for a change an older reader must not ignore, keep reading every earlier version, and add a sample for the new version beside the old one.
