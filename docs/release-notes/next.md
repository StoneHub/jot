# Jot (next release)

Jot can now appear in Vorssaint's Dynamic Island. Jot.app includes a small helper, jot-vorssaint, that a Vorssaint build with native app features can turn on: a Listening switch, Start and End Meeting, Open Jot and Quit Jot, plus capture and processing feedback while you dictate. The helper sees only Jot's listening state, microphone level, dictation progress and how long a meeting has run; no meeting title, target app or audio leaves Jot, and transcript text only as the preview below. Turning the feature on never starts the microphone. Switching Listening off in the island pauses right away and also ends any meeting in progress. Stock Vorssaint does not include native app features yet, and Jot works the same without it.

A new General → App setting, "Always show menu bar icon", is on by default. Turn it off and Jot hides its own icon only while Vorssaint's Jot feature is running. The icon comes back when the feature is turned off or Vorssaint quits.

A second App setting, "Share transcript preview", is on by default: while Jot listens, the Island can show the last line Jot heard, up to 180 characters with the speaker's name. Dictation is never shown, only Jot's own Vorssaint helper can read the line, and Vorssaint does not save it. Turn it off to keep all transcript text inside Jot.

Cleanup, suggestions and session notes can use a model you choose instead of Apple Intelligence: a server on this Mac, such as Ollama or LM Studio, or a hosted OpenAI-compatible or Anthropic API with your own key. Set it up in General → Custom model. Each use stays off until you switch it on, and Test connection sends no transcript text.

New Appearance settings keep Jot light or dark whatever the Mac uses, and pick its accent color.

Activity now shows usage counters: how holds ended, how text was inserted, and what cleanup and suggestions did. They hold no text, stay on this Mac, and can be reset.

In Low Power Mode, listening reads the microphone less often, uses longer recognition chunks and skips live cleanup. Quiet rooms cost less CPU too.

For agents and the command line: `jot notes <session-id>` writes meeting notes on request without saving them, `jot vocabulary export` and `jot vocabulary import` move personal vocabulary between Macs, and the MCP server adds transcripts_wait, sessions_notes and vocabulary tools.

Setup now says Jot keeps running in the menu bar, explains missing speech models, and warns when macOS also acts on the Fn/Globe key. Jot asks for Accessibility only when dictation or suggestions need it.

Updating installs a downloaded Jot into Applications instead of reopening the older copy, and Jot keeps running if an update can't replace the installed app.

Fixes:
- End Meeting now exports after the last phrase is cleaned up. It waits about 15 seconds at most, then saves the rest as recognized.
- A long hold is no longer marked partial because of audio dropped after you let go.
- A short tap while paused no longer deletes the dictation kept for "Review saved dictation".
- A finished dictation no longer stays stuck as "recognizing" until the next launch.
- After waking from sleep, Jot no longer pauses with "Microphone stopped delivering audio" right after the microphone comes back.
- Picking a microphone during Setup no longer cancels the model download.
- The jot CLI, MCP tools and menu bar controllers no longer stop responding until relaunch after a dropped local connection.
- `jot listen` does much less work while it waits.
- Listen from Vorssaint on a fresh install asks before downloading speech models.
- A suggestion's field outline no longer disappears after one slow read, and a finished older suggestion no longer changes the newer one.

No new macOS permissions. Jot still requires macOS 14 or later.
