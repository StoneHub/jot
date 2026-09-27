#!/bin/bash
# The host bounds this hook to three seconds; Jot bounds the local socket call to two.
# Hook output can enter the agent conversation, so both streams stay empty.
jot=/Applications/Jot.app/Contents/Helpers/jot
if [ -x "$jot" ]; then
    "$jot" agent-context --source claude-code >/dev/null 2>&1
fi
# Drain any input left by a missing or older helper before the host closes its pipe.
cat >/dev/null 2>&1
exit 0
