# Jot context for Codex

These hooks pass a submitted Codex prompt and the finished assistant message to [Jot](https://github.com/StoneHub/jot) on the same Mac. A Jot suggestion requested in the focused Codex composer can use the recent conversation as attributed context. The package is source code in this repository; checking it out does not install or enable hooks.

`UserPromptSubmit` and `Stop` each call `/Applications/Jot.app/Contents/Helpers/jot agent-context --source codex` with the event JSON on standard input. The Stop event provides `last_assistant_message`, so no transcript parsing is needed. Jot keeps bounded context in memory and forwards it only to its same-user local service. The hooks return no output and exit successfully even when Jot is missing or unavailable. They do not send a prompt, run a command, or accept a suggestion for you.

## Enable locally

Install Jot in `/Applications`. If this package is installed and enabled as a Codex plugin, its `hooks/hooks.json` is discovered from the package. Review and trust the two exact hook commands with `/hooks`; Codex skips untrusted plugin hooks. Installing or changing the package never bypasses that review.

For a local checkout without a configured plugin marketplace, put the following in your chosen Codex hook configuration (`~/.codex/hooks.json` for all local projects, or `<repo>/.codex/hooks.json` for one trusted project). Adjust the script path if this repository lives elsewhere. This is an alternative to enabling the plugin: use one registration method so each event is delivered once.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "bash \"$HOME/Developer/GitRepos/jot/integrations/codex/jot-context/hooks/send-to-jot.sh\"", "timeout": 3}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "bash \"$HOME/Developer/GitRepos/jot/integrations/codex/jot-context/hooks/send-to-jot.sh\"", "timeout": 3}]}
    ]
  }
}
```

Use `/hooks` to inspect and trust the exact local definition. Codex records trust for the current hook contents and skips changed hooks until reviewed again. If an older Jot hook is present, disable it before enabling this one.

## Check

Start a fresh Codex session after installing. Submit a prompt, wait for the answer, then inspect `jot status` for a nonzero agent-context count. Double-tap Fn in the Codex composer to see whether Jot names the agent conversation. These hooks need a local execution environment and do not run in ordinary ChatGPT chat.

On September 27, 2026, the installed plugin's two commands were reviewed with `/hooks`; the runtime reported both enabled and trusted. A real Codex CLI turn delivered its prompt and completed reply to the installed Jot app. A subsequent turn through the Codex desktop host delivered its completed reply too. A physical double-Fn request in the native composer is still a separate acceptance check. The local hooks need no API key or account login; generating a real agent reply for an end-to-end test uses that agent's normal authentication.
