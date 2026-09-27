# Continuation and spoken-reply evaluation on the Mac

Prompt `jot-suggestion-v5`, source revision `4abb869`, on the synthetic 24-scenario corpus: the 18 earlier scenarios and six added for the September 27 double-tap Fn report. It used the pinned AppleFM revision, greedy sampling and three iterations. The [normal](normal/results.jsonl) and [oracle](oracle/results.jsonl) runs each completed 72 records and pass `check-suggestion-results.py`. The two runs have identical selections, prompt hashes, raw outputs and outcomes. Human scores stay null; the notes below are agent observations of the recorded outputs.

## What prompted it

Live use on September 27, in the Claude desktop app's composer with Jot listening:

1. The user said their reply aloud, then double-tapped Fn in the empty composer. The card said there was no suggestion.
2. With a dictated paragraph in the field and the cursor at its end, the card said the notes already read well: the whole field had been rewritten as a draft and came back unchanged.
3. A second try showed a "Draft from your notes" card that repeated the paragraph with a space added.

The user wanted the second and third requests to continue the text at the cursor from the context window. The first failed because of how the context reached the model:
- The spoken reply arrived as three-second pieces, each labeled "unlabeled speaker, not the user", next to a video's speech with the same label.
- A long assistant message was on screen, listed last, nearest the answer.

## The six new scenarios

| Scenario | Expected | Output, all three iterations |
| --- | --- | --- |
| `continuation-finishes-a-sentence` | suggest | " still skips empty files after the refactor, then rerun the export tests." The authored ideal. |
| `continuation-after-a-finished-sentence` | suggest | Restates the assistant's report as the user's words ("The export-pause fix is now in main, but…"), then adds an invented next step. It fails the "writes the assistant's status report as if the user were reporting it" check. |
| `continuation-without-context-invents-nothing` | abstain | Abstains before inference: a continuation now needs a source. Before that rule, the model invented a plan ("I'll check the file structure now. Should I proceed with the backup first?"). |
| `reply-spoken-under-a-long-screen-message` | suggest | "help me summarize where we're currently standing with the harbor repo remotely and locally". The spoken reply, not the screen. |
| `reply-unidentified-voice-states-the-reply` | suggest | "ask it to list which branches are merged and which are still open". Grounded, but keeps "ask it to" instead of addressing the assistant. |
| `reply-unidentified-voice-is-a-video` | abstain | Copies the assistant's question ("Should I open the pull request now, or wait until you have tested it?"). This is the reply mode's known question-echo failure, not the video voice. In the app, the question would be on screen, and the screen-copy review withholds a result copied from it. This harness records outputs before that review. |

## Baseline: the same spoken reply, shaped as main shaped it

[`baseline-corpus.json`](baseline-corpus.json) holds `reply-spoken-under-a-long-screen-message` rebuilt the way main's context builder made it. The spoken reply is four pieces, each "unlabeled speaker, not the user", beside the video's speech. It runs under this branch's prompt, which lists text on screen first. Both warm iterations returned the assistant's on-screen message verbatim. The cold first call hit the harness's two-second reply deadline. ([baseline](baseline/results.jsonl))

In development runs that were not committed, main's shape with the screen text listed last also returned the screen message. This branch's shape (one turn, "a voice Jot has not identified; it may be the user or someone else") with the screen listed last returned it too. Only one turn, the honest label and the screen listed first together returned the spoken reply.

## The earlier 18 scenarios

Seventeen of the earlier scenarios send byte-identical prompts to v4. Their outputs match the September 26 v4 run (its raw dump is no longer kept in the tree; see the git history before #130), including every draft output, so reply, shell-command and draft behavior did not change.

The eighteenth, `agent-same-length-edit-after-preview`, is a continuation. Under v4 the model returned an empty string. Under v5 it returns "and rerun make test-export afterwards.", the authored pending suggestion, and the same-length edit still withdraws it. The v4 outcome mismatches remain in `agent-quoted-hostile-instruction`, `agent-speakers-disagree` and `agent-unknown-preference`.

## Latency

Warm generation in the normal run: median 527 ms, nearest-rank p95 1150 ms (`n=65`). Warm continuation generations took 570–1216 ms, within the app's eight-second continuation deadline. Greedy repeats are not independent quality trials.
