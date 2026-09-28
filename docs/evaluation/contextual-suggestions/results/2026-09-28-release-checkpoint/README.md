# September 28 release checkpoint

Mac validation at `d481bf1`, including #154–#157. One iteration of each of the 27 synthetic scenarios per configuration, using the real on-device model. Raw outputs, prompts and run metadata are in [default](default/) and [window](window/). Scores remain unassigned.

| Configuration | Selection matches scoped corpus | Outcomes | Warm preview median / p95 | Samples |
| --- | --- | --- | --- | --- |
| Default: 6 sources, 4096 bytes, scoped | 27/27 | 21 suggest, 4 abstain, 2 invalidate | 635.5 / 1084 ms | 22 |
| App: 12 sources, 6000 bytes, explicit | 21/27 | 20 suggest, 5 abstain, 2 invalidate | 643 / 1126 ms | 21 |

The corpus expectations describe the scoped defaults. The app configuration intentionally admits more sources, so its six selection differences are not six selector regressions. The three new scenarios have only 7–8 sources: they exercise the default six-source bound, but do not fill the app's twelve-source bound. These runs therefore do not establish relevance selection at the production bound. Preview p95 uses nearest rank over warm successful previews, including invalidated previews; this small sequential sample is not a before/after performance benchmark.

| New scenario | Default | App configuration |
| --- | --- | --- |
| Video after spoken reply | Relevant reply, 840 ms | Same reply, 891 ms |
| Phone call during Slack reply | Asked for confirmation rather than directly stating the supplied invoice plan, 787 ms | Model abstained |
| Two meeting topics | Relevant malformed-row reply, 739 ms | Same reply, 829 ms |

Default selections reproduced all 27 authored expectations; none were changed. The agent conversation unit test's negative control was corrected: with no conversation target, the user's own message still survives under #155, while the assistant turn is crowded out. The positive assertion still requires both matched conversation turns to survive. Xcode's generated project was updated to include DirectoryLock.swift and UserVoice.swift.

Mac checks passed: 323 Swift tests, 48 Python tests, fixture validation, signed Debug and Release builds, no-feedback checks, recovery controller checks, and real-model recovery using synthetic speech. The real audio check delivered one 18.944-second hold in eight bounded chunks and processed a 0.25-second final chunk. No private recordings were used.

Keep #140 open: add cases exceeding twelve sources/6000 bytes and compare latency against a matched baseline. Physical double-Fn/Tab insertion, two live agent conversations, and learning/recognizing the owner's real voice remain end-to-end checks for normal use.
