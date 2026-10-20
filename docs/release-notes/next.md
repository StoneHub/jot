# Jot (next release)

Jot can now appear in Vorssaint's Dynamic Island. Jot.app includes a small helper, jot-vorssaint, that a Vorssaint build with native app features can turn on: a Listening switch, Start and End Meeting, Open Jot and Quit Jot, plus capture and processing feedback while you dictate. The helper sees only Jot's listening state, microphone level and dictation progress; no transcript, meeting title, target app or audio leaves Jot. Turning the feature on never starts the microphone. Switching Listening off in the island pauses right away and also ends any meeting in progress. Stock Vorssaint does not include native app features yet, and Jot works the same without it.

A new General → App setting, "Always show menu bar icon", is on by default. Turn it off and Jot hides its own icon only while Vorssaint's Jot feature is running. The icon comes back when the feature is turned off or Vorssaint quits.

Fixes:
- End Meeting now exports after the last phrase is cleaned up. It waits about 15 seconds at most, then saves the rest as recognized.
- A long hold is no longer marked partial because of audio dropped after you let go.
- A short tap while paused no longer deletes the dictation kept for "Review saved dictation".
- A finished dictation no longer stays stuck as "recognizing" until the next launch.
- After waking from sleep, Jot no longer pauses with "Microphone stopped delivering audio" right after the microphone comes back.
- Picking a microphone during Setup no longer cancels the model download.
- The jot CLI, MCP tools and menu bar controllers no longer stop responding until relaunch after a dropped local connection.
- `jot listen` does much less work while it waits.

No new macOS permissions. Jot still requires macOS 14 or later.
