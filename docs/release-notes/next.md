# Jot (next release)

Saved history is now encrypted on disk. Transcripts, cleaned text, speaker names, remembered voices and the rest of Jot's database are encrypted with SQLCipher under a key that stays in your login keychain, so a backup or a copy of the Jot folder is unreadable without it. The first launch converts the existing history in place, once, keeping every row. Nothing changes for you or your agents: Jot, `jot` and the MCP server read history as before, with nothing to type. **General → Privacy → History key** shows the key for opening this history on another Mac, and takes a key from another Mac when a copied history will not open. Session audio kept for a speaker pass or for tuning is not encrypted. Earlier versions of Jot cannot open the converted history.

`jot clients` lists which programs called Jot, by method and day, for the last 90 days, so you can see which agents read history. The log counts calls only, never transcript text, and deleting history leaves it.

The anonymous usage counts now also say how long dictation took to appear (in rough ranges such as "under one second"), how meetings started and ended and roughly how long they ran, and which features were switched on that day, such as Fix typos or cleanup. They still never include transcripts, audio, app names, or a custom model's address or name. Settings → Privacy → Share anonymous usage counts turns sharing off.

When recognition stalls, listening no longer keeps every chunk of audio waiting for it without limit. The queue holds ten minutes of audio, sentence-closing chunks included; audio past that is counted as one gap in History and the Dropped audio figure, with a notice, until recognition catches up. Pause, End meeting and a released dictation stop waiting on a recognition that has given no answer for thirty seconds, keep the queued speech for a restart, and say what is still waiting. Choosing Unload Models and then Resume restarts recognition on the queued speech, beginning with the block it was stuck on.

A session whose last chunk failed in recognition still gets its last phrase cleaned up, so Regroup and the speaker pass wait for that cleanup instead of writing over it, and the next session's first phrase is cleaned on its own.

The third-party notices in the app bundle now list each speech model Jot downloads, with its authors and license.
