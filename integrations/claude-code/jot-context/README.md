# Jot context for Claude Code

This plugin lets [Jot](https://github.com/StoneHub/jot) know the Claude Code conversation you are in. When you double-tap Fn in Claude's composer, Jot's suggestion answers your latest prompt and Claude's latest reply, not just the text it can read on screen.

## What it sends, and where

Two hooks run `jot claude-context`, the CLI bundled with Jot:

- **UserPromptSubmit** sends the prompt you just submitted.
- **Stop** sends Claude's final message for the turn. Claude Code does not put the reply in the hook, so the CLI reads the last 512 KB of the transcript file the hook names, never the whole file.

Each event carries the session ID and working directory. Texts are capped at 4,000 characters. They go only to Jot's same-user Unix socket on this Mac. Jot keeps the latest three exchanges of up to four sessions in memory for an hour. It never writes them to disk or its database, and does not offer them over MCP. `jot status` shows only how many sessions it holds and how long ago the last update arrived. Turning off **General → Suggestions → Use the Claude Code conversation** makes Jot drop the updates and forget what it held.

The hook prints nothing and always succeeds, so it never adds text to Claude's context and never holds up a prompt. When Jot is not installed or not running, it does nothing. Subagent events are ignored.

## Install

Jot must be installed in `/Applications`, or its CLI linked at `~/.local/bin/jot`. In Claude Code:

```
/plugin marketplace add StoneHub/jot
/plugin install jot-context@jot
```

From a shell, `claude plugin marketplace add StoneHub/jot` and `claude plugin install jot-context@jot` do the same. Restart any open Claude Code sessions, including the Claude app's Code tab, so they load the hooks.

## Uninstall

```
/plugin uninstall jot-context@jot
/plugin marketplace remove jot
```

## Check it

With Jot running, submit a prompt in Claude Code, wait for the reply, then run `jot status`. `suggestions.conversation.sessions` counts the sessions Jot holds and `secondsSinceUpdate` says when the last one arrived. To see what the CLI would send without sending it, pipe a hook event to `jot claude-context --print`.
