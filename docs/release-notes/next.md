# Jot (next release)

The anonymous usage counts now also say how long dictation took to appear (in rough ranges such as "under one second"), how meetings started and ended and roughly how long they ran, and which features were switched on that day, such as Fix typos or cleanup. They still never include transcripts, audio, app names, or a custom model's address or name. Settings → Privacy → Share anonymous usage counts turns sharing off.

When recognition stalls, listening no longer keeps every chunk of audio waiting for it without limit. The queue holds ten minutes of audio, sentence-closing chunks included; audio past that is counted as one gap in History and the Dropped audio figure, with a notice, until recognition catches up. Pause, End meeting and a released dictation stop waiting on a recognition that has given no answer for thirty seconds, keep the queued speech for a restart, and say what is still waiting. Choosing Unload Models and then Resume restarts recognition on the queued speech, beginning with the block it was stuck on.

A session whose last chunk failed in recognition still gets its last phrase cleaned up, so Regroup and the speaker pass wait for that cleanup instead of writing over it, and the next session's first phrase is cleaned on its own.

The third-party notices in the app bundle now list each speech model Jot downloads, with its authors and license.
