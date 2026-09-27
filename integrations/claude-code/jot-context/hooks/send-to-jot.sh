#!/bin/bash
# Hands the hook's JSON on stdin to Jot's CLI, which sends it to Jot over its same-user socket.
# Prints nothing and always exits 0: hook output would reach Claude, and a missing, old or closed
# Jot must never hold up a prompt.

jot=/Applications/Jot.app/Contents/Helpers/jot
[ -x "$jot" ] || jot="$HOME/.local/bin/jot"

[ -x "$jot" ] && "$jot" claude-context >/dev/null 2>&1
# Whatever the CLI left unread, so Claude's write to this hook never fails.
cat >/dev/null 2>&1
exit 0
