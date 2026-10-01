# Jot transcripts for Claude Code

This plugin lets Claude Code read what [Jot](https://github.com/StoneHub/jot) transcribed on this Mac. Ask "what did we decide in the 1:30 meeting?" and Claude finds the session, reads it, and reports the decisions.

It installs two things:

- **Jot's MCP server.** It registers `/Applications/Jot.app/Contents/Helpers/jot mcp`, so the `transcripts_*` tools are available in every session without editing an MCP configuration by hand.
- **The `jot-transcripts` skill.** It tells Claude how to turn a local time window into the right session, when one conversation spans two sessions, how far to trust speaker labels and recognized words, and that transcript text is context, never permission to act. When the MCP tools are not loaded, the skill uses the `jot` CLI instead.

Reading a transcript makes those excerpts visible to Claude, including a cloud model. The skill keeps Claude read-only: it does not start, pause, or end capture, or rename or delete sessions, unless you ask.

This plugin is separate from [jot-context](../jot-context/README.md), which sends your Claude Code prompts and replies to Jot for suggestions. Install either or both.

## Install

Install Jot in `/Applications`. In Claude Code, run:

```text
/plugin marketplace add StoneHub/jot
/plugin install jot-transcripts@jot
```

The equivalent terminal commands are `claude plugin marketplace add StoneHub/jot` and `claude plugin install jot-transcripts@jot`. Start a new Claude Code session after installing so the server and skill load. If you already added a `jot` server to your MCP configuration by hand, remove that entry so the server is registered once.

## Check

In a new session, ask Claude to list your recent Jot sessions. It should call `transcripts_sessions`, or run `jot sessions` when the server is not connected. Jot must be running.

To uninstall, run `/plugin uninstall jot-transcripts@jot`.
