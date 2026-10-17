# Jot 0.2.9

Single-word held dictation inserts without a trailing period and bypasses the prose model. This happens before explicit spoken symbols and personal vocabulary are applied, so a dictated "period" and preferred spellings keep their punctuation. Recognized source text and existing input-field text are preserved.

Apple Intelligence dictation cleanup now distinguishes phrase fragments from complete sentences: "the blue one" stays open, while "I want the blue one" gets a period. The single-word fix also works with cleanup disabled or unavailable.

Also includes the changes already on main since 0.2.8: a first-install setup page that resumes progress, automatic recovery from silent microphones, updates that wait for active listening to finish, and preserving the current tab when changing microphones.

Development prerelease, signed with Monroe's Apple Development identity; not notarized. Requires a Mac that trusts this development certificate. Basic app support starts at macOS 14; Apple Intelligence enhancements require compatible hardware and macOS 26 or later. Transcripts and audio stay on the Mac. Models download separately.

Validation: 364 Swift tests, 48 Python tests, signed app builds, recovery-controller checks, and the actual on-device model distinguishing fragments from short complete sentences. Synthetic audio exercises real recognition and dictation delivery.

Test when you sit down: hold Fn to insert one word in the middle of an existing sentence; try "the blue one" and "Go now" with dictation cleanup on; say "purple period" to request an explicit dot. Check that surrounding text stays intact. Physical Fn and cross-app Accessibility behavior remain user checks.
