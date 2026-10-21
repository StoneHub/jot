# Shared contract: Jot for Mac and Jot for Android

Jot for Mac (this repository) and Jot for Android ([StoneHub/jot-android](https://github.com/StoneHub/jot-android)) share no code. They share the files and rules below, so a person can move their own data between the two and both apps behave the same way on it. This document is the spec; when an app and this document disagree, fix one of them in the same change.

## Principles

- **Files, not a service.** Everything here is a local file the person makes and moves themselves: AirDrop, a USB cable, a folder they already sync. Neither app uploads it, and there is no Jot sync service or account. A future transport (for example a local network handoff) must carry these same files unchanged.
- **Every file names its format and version.** A JSON file carries `"format"` and an integer `"version"`. A reader refuses a format it does not know and a version newer than it reads, with a message that says to update the app. It never reads a newer file in part.
- **Unknown fields are ignored.** Within a version, a writer may add optional fields that an older reader can safely skip. A change that alters what an existing field means, or that an older reader must not ignore, takes a new version number.
- **Ids stay on the device.** Database and entry ids are local. Files carry content, not ids, and a reader matches by content.
- **No private data in fixtures.** Shared samples under `docs/contract/` are synthetic.

## Personal vocabulary file (`jot.vocabulary`, version 1)

Status: Mac writes and reads it (`jot vocabulary export` and `jot vocabulary import`, `VocabularyFile` in JotCore). Android does not have personal vocabulary yet; when it does, it reads and writes this file. Sample: [`docs/contract/vocabulary-v1.json`](contract/vocabulary-v1.json), which `VocabularyFileTests` reads, and an Android test should read too.

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

## Session export (Mac only today, not yet versioned)

The Mac writes a finished meeting to `~/Documents/Jot Sessions` as Markdown (`TranscriptExport.markdown`). This layout is what people and other tools already read, so it changes only on purpose:

```markdown
# <title, or "Session"> <yyyy-MM-dd HH:mm zone>

Session <session id>. <n> segments, <h:mm:ss> of audio, ending <yyyy-MM-dd HH:mm zone>.
Speakers without a name are Jot's automatic groupings. Timestamps are offsets from session start.

**[h:mm:ss] <Speaker>:** <paragraph text>
```

`<Speaker>` is the person's label, else `Speaker N`, `Overlap` or `Unattributed`. Paragraphs join the same speaker's rows across short pauses.

`jot export <session-id> --json` (and MCP `transcripts_export` with `format: "json"`) answers with the session's rows, under `result`, as a JSON array of `{id, sessionID, startedAt (ISO 8601), startSeconds, endSeconds, text, mode ("ambient" or "dictation"), speakerID?, speakerLabel?}`, with continuations folded but paragraphs not merged. This is the socket's answer, not a file format: before Android reads or writes sessions, wrap it in a `{"format": "jot.session", "version": 1, ...}` file and specify it here.

## Cleanup rules (each app has its own copy today)

Both apps use a small on-device model to remove filler and fix punctuation, and both keep the original text when the result looks unsafe. The prompts and checks were written separately and differ:

| | Mac (`JotSettings.defaultCleanupInstructions`, `CleanupValidation`) | Android (`CleanupNpu.kt`, `CleanupChecks`) |
| --- | --- | --- |
| Input | Batches of transcript entries, returned as `texts` | One dictation up to 1,200 characters |
| Rejects empty output | Yes | Yes |
| Rejects long output | Over max(120, 2 × input) UTF-8 bytes | Warns over max(80, 2 × input) characters |
| Numbers | The sequence of digit tokens and number words (zero…trillion, first, half, percent, point…) must match | The sequence of digit runs must match |
| Negations and hedges | The sequence of negations and hedges (not, never, can't, maybe, probably, unless…) must match | The count of ten negations must match |
| Control text | Not checked | Rejects `<think>` and `<|` |

The shared target is one written rule set and one synthetic test corpus (source, accepted and rejected outputs) under `docs/contract/` that both apps' tests run. Until that lands, change one app's rules only together with this table.

## Changing this contract

Add or change a rule here in the same pull request as the code. Bump a file's `version` only for a change an older reader must not ignore, keep reading every earlier version, and add a sample for the new version beside the old one.
