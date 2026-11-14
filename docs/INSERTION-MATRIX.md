# Real-app insertion matrix

`local-pr-check`'s gates prove that dictation's delivery code builds and behaves against a synthetic field. They never
put text into a real app. This matrix does: the app's own `DictationInput` code (`Sources/Jot/DictationInput*.swift`)
delivers one fixed phrase into real apps, reads each field back through Accessibility, and a password field has to
refuse it. It is the release checklist for dictation: `release.py` refuses to cut a release unless the matrix passed on
the exact commit being released.

## The rows

| Row | App and field | Must |
| --- | --- | --- |
| `textedit` | TextEdit, a new document | verify the phrase in the field (expected path `accessibility`) |
| `safari` | Safari, a `<textarea>` on a local page the check writes | verify the phrase |
| `password` | Safari, an `<input type="password">` on a second local page | refuse before any write, with the secure-field error |
| `terminal` | Terminal, a new window's shell prompt | verify the phrase (expected path `unicode_hid`; Jot never presses Return) |
| `electron` | the Electron app you name, a field you give it | verify the phrase |

The phrase is `Jot insertion matrix check 0427.`: punctuation, digits and a sentence end, so cleanup-style text goes
through every path. `--phrase` changes it.

A row passes when the delivery is `verified` by Jot's own read-back and the field's Accessibility value then holds
the phrase; the password row passes only when `captureTarget` throws the secure-field error. The report records the
path (`accessibility`, `unicode_hid`, `clipboard_hid`), the outcome, the field's role and subrole, and a note. Field
contents are never written to the report.

## Run it

On the Mac, from the commit you mean to release:

```sh
cd ~/Developer/jot && python3 scripts/insertion_matrix.py --electron com.microsoft.VSCode --electron-new n
```

The script builds `JotRecoveryChecks`, runs `--insertion-matrix`, prints the table, and writes
`build/insertion-matrix.json` with the HEAD it checked. `--electron-new n` sends Command-N to the Electron app so a
fresh untitled file is focused without a click; without it, click into an editable field in that app when the check
asks (it waits 45 s). `--binary <path>` reuses a built tool; `--skip <row>` leaves a row out, and the proof then does
not count for a release.

The check opens TextEdit, Safari and Terminal itself, through `osascript` and `open`, and closes what it opened: the
TextEdit document (unsaved), the two Safari tabs and the Terminal window. The Electron field keeps the phrase; delete
it afterwards. Keep your hands off the keyboard and mouse while it runs: a focus change cancels the row, as it does a
real dictation.

Permissions, granted once to the terminal app that runs the script (Terminal or iTerm), because macOS attributes a
command-line tool to it:

- **Accessibility** (System Settings → Privacy & Security → Accessibility), for reading fields and posting key events.
  Without it the check stops at once.
- **Automation** prompts for TextEdit, Safari, Terminal and, with `--electron-new`, System Events, the first time.

Jot.app can keep running. The check never starts capture, the shortcut listener or a socket; it only uses the delivery
code, so its result says how real apps take Jot's text, not whether the hold or recognition worked. Those stay on the
end-to-end list.

## Releases

`release.py` reads `build/insertion-matrix.json` and refuses when it is missing, was made on another commit or a dirty
tree, or any row did not pass. Run the matrix again after every merge you release. `--skip-insertion-matrix` cuts the
release anyway and says so in its output; use it when the release does not touch dictation and the Mac cannot open the
apps, not to get past a failed row.

A failed row is a bug to fix forward, or an app limit to record here. Record each app's expected path in the table
above when it changes.

## What it does not prove

- The shortcut, the hold, recognition and cleanup: the matrix starts at delivery. Dictate once into each app by hand
  when those change.
- Fields in apps the matrix does not open: browsers other than Safari, chat composers, web apps inside Electron.
- Jot.app's own permission grants: the matrix runs under the terminal's grants.
