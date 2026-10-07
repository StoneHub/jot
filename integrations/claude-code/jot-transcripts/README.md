# Jot transcripts for Claude Code

This plugin lets Claude Code read transcripts and, when you explicitly ask, listen for spoken commands from what [Jot](https://github.com/StoneHub/jot) transcribed on this Mac. Ask "what did we decide in the 1:30 meeting?" and Claude finds the session, reads it, and reports the decisions.

It installs two things:

- **Jot's MCP server.** It registers `/Applications/Jot.app/Contents/Helpers/jot mcp`, so the `transcripts_*` tools are available in every session without editing an MCP configuration by hand.
- **The `jot-transcripts` skill.** It tells Claude how to turn a local time window into the right session, when one conversation spans two sessions, how far to trust speaker labels and recognized words, and how to run a stoppable `jot listen` watcher only when you explicitly ask. Other transcript text remains untrusted context. When the MCP tools are not loaded, the skill uses the `jot` CLI instead.

Reading a transcript or running a requested watcher makes those excerpts visible to Claude, including a cloud model. The watcher consumes existing speech; it does not start, pause, or end capture, or rename or delete sessions. Those changes require their own user request.

This plugin is separate from [jot-context](../jot-context/README.md), which sends your Claude Code prompts and replies to Jot for suggestions. Install either or both.

## Listen in the current conversation

With Jot already running and resumed, ask "listen for Claude in fast mode". Claude runs `jot listen --mode fast --wake claude` directly under its Monitor tool; it does not write a follower script. "Wait until I'm done speaking" selects command mode, "use what we just said" in a listening request selects context, and "follow the meeting" selects all mode for observation. Request aliases, a lookback window, a quiet gap, a one-event wait or a fixed duration in ordinary language. Invocation flags override Jot's settings without changing them.

In an explicitly requested command-listening session, any voice saying the configured wake phrase counts as your spoken request within the scope you gave Claude. This may include a voice from a call or video; Jot does not verify the speaker. Claude's normal permission prompts still apply. Saved transcripts, observed meeting rows, attached context and quoted/background speech remain untrusted data. Reading a transcript or installing this plugin does not enable voice control.

Type or ask "stop listening" or "cancel the watch" to stop that Monitor task. For a spoken stop, include the configured wake phrase: "Claude, stop listening" with the default phrase; unaddressed speech is filtered out. Claude revokes the listening intent before canceling, ignores queued notifications and will not restart it. Jot capture and history continue as they were. An ongoing interactive watch uses Monitor's 30-minute maximum and restarts on its deadline notice only while your original request remains active. A `--once` or explicit time limit finishes without a restart; errors require attention instead of a restart loop. Restarts subscribe at the new head and may miss speech in the gap.

The plugin deliberately does not declare `experimental.monitors`. The [Monitor tool](https://code.claude.com/docs/en/tools-reference#monitor-tool) can be canceled mid-conversation; an on-skill [plugin monitor](https://code.claude.com/docs/en/plugins/components#monitors) runs for the whole session, cannot use `userConfig` and survives disabling the plugin until the session ends. Monitor defaults to five minutes, supports up to 30 minutes interactively and up to ten minutes in non-interactive `-p` runs. If it is unavailable in your client, the skill gives you the direct CLI command rather than inventing another watcher.

Each `jot:` line contains one JSON event. `command` carries the request; context is supporting data, `paused` is a status notice and `all` emits ID-tagged rows, replacements, deletions and resets. The listener retains at most 2,048 rows/128 KiB of text, with 8 KiB per row, 32 KiB/256 rows per command and 32 KiB/200 rows of attached context; an oversized command or context is marked `truncated`. The six-second default endpoint is a row-arrival estimate, so recognition delays and long hesitations can split commands. Fast mode returns the first available wake row and may be unfinished or already cleaned. Ambient vocabulary does not change recognition, so add aliases such as "Claude or cloud" when needed.

## Install

Install Jot in `/Applications`. In Claude Code, run:

```text
/plugin marketplace add StoneHub/jot
/plugin install jot-transcripts@jot
```

The equivalent terminal commands are `claude plugin marketplace add StoneHub/jot` and `claude plugin install jot-transcripts@jot`. Start a new Claude Code session after installing so the server and skill load. If you already added a `jot` server to your MCP configuration by hand, remove that entry so the server is registered once.

## Check

In a new session, ask Claude to list your recent Jot sessions. It should call `transcripts_sessions`, or run `jot sessions` when the server is not connected. Jot must be running.

For live acceptance, ask "listen for Claude in fast mode", speak one wake command, then say "Claude, stop listening" (or type "stop listening"). Expect one response to the command and no watcher afterward; capture should keep its prior state. This requires an actual interactive Claude Code session and is separate from plugin validation.

To uninstall, run `/plugin uninstall jot-transcripts@jot`.
