# Jot context for Claude Code

This plugin passes the prompt you submit and Claude Code's finished reply to [Jot](https://github.com/StoneHub/jot) on this Mac. When you explicitly request a suggestion in Claude's composer, Jot can use the recent conversation as attributed context.

The `UserPromptSubmit` and `Stop` hooks pass their JSON input to `/Applications/Jot.app/Contents/Helpers/jot agent-context --source claude-code`. The Stop event supplies `last_assistant_message`; the hook never opens a transcript file. Jot keeps bounded context in memory and sends it only to its same-user local service. The hooks print nothing, always exit successfully, and do nothing when the Jot helper is missing. They do not send a prompt, run a command, or accept a suggestion for you.

## Install

Install Jot in `/Applications`. In Claude Code, run:

```text
/plugin marketplace add StoneHub/jot
/plugin install jot-context@jot
```

The equivalent terminal commands are `claude plugin marketplace add StoneHub/jot` and `claude plugin install jot-context@jot`. Start a new Claude Code session after installing so the hooks load. If you previously installed hand-written Jot hooks, remove those registrations before enabling this plugin; each event should run once.

## Check

Submit a prompt, wait for Claude Code's reply, then inspect `jot status` for a nonzero agent-context count. Double-tap Fn in Claude's composer to see whether the suggestion names the agent conversation. Hook delivery from the Claude desktop Code tab has not yet been verified in a live session.

On September 27, 2026, the installed plugin's real `UserPromptSubmit` event delivered a prompt to Jot with empty stdout/stderr and a successful exit. The shared helper and both hook payloads also passed synthetic local-socket checks. A completed Claude reply and a physical double-Fn request in the desktop Code tab remain separate acceptance checks. The hooks are entirely local and need no API key or account login; authentication is only needed by Claude itself when generating a real reply for a test.

To uninstall, run `/plugin uninstall jot-context@jot`. Removing the marketplace as well is optional: `/plugin marketplace remove jot`.
