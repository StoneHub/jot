# Swarm

A swarm of agents works Jot's issue queue. Two leads take turns over one shared state, and short-lived workers each take one issue.

[AGENTS.md](../AGENTS.md) governs proportional checks and delivery authority. Coordination below assigns owners; it does not add blanket native-validation, review or release gates.

- **On duty:** Codex Monday to Friday, Claude Saturday and Sunday (US Eastern). Claude swarm jobs are scheduled only on weekends.
- **Host:** Monroe's MacBook Pro runs both leads and every Mac worker.
- **State:** GitHub only. Labels, blocked-by links, the pinned control issue [#201](https://github.com/StoneHub/jot/issues/201) and [PLAN.md](PLAN.md). Whatever a chat knows that isn't written there is lost at the next hand-off.

## Labels

| Label | Meaning |
| --- | --- |
| `ready` | Specified and unblocked. Any worker may claim it. |
| `in-progress` | Claimed. The claim comment names the tool (`codex` or `claude`), the host and the branch. |
| `needs-mac` | Needs a native build or test. Issues without it can be done in the cloud. |
| `needs-monroe` | Waiting on Monroe: a decision, a recording, a physical test or an attestation. |
| `blocked` | Waiting on its blocked-by issues. Mirrors GitHub's blocked-by links. |
| `parked` | Not now. |
| `area:*` | Conflict control. `area:core` and `area:suggestions` hold one claim at a time; other areas run in parallel. |

## Work an issue (worker)

1. Claim: an issue labelled `ready`, with no open blocked-by issue, in an area that has room. Swap `ready` for `in-progress` and comment `claimed by <tool> on <host>, branch <branch>`.
2. Isolate concurrent changes on that branch in a worktree when needed. Run the affected build and meaningful behavioral checks; use a regression when it catches a real failure or protects a durable contract. Cloud workers follow [CLOUD-WORK.md](CLOUD-WORK.md).
3. Review the diff; seek independent review when consequential threading, persistence or other unresolved risk warrants it.
4. Open the PR linking the issue, the checks you ran and their results, what you couldn't run, and a short **test when you sit down** list for Monroe. Close the issue only when its agreed outcome is complete.

Done when the PR is open and marked ready for review, and the claim comment links it. Merging belongs to the lead.

## Merge rule

The lead on duty owns integration, one PR at a time, after the affected checks available in the worker's environment pass. Review the current diff and integration boundaries; broaden only when they, failures or unresolved risk warrant it. The optional `local-pr-check` selects diagnostic checks; statuses, native-only checks and per-PR device validation are not standing merge requirements. Report relevant checks that could not run.

The `app-behavior` and real-model-audio attestations aren't merge gates. They go on Monroe's daily test list, and a failure he finds is fixed forward. Workers, cloud ones included, open PRs and leave merging to the lead.

## Tick (lead on duty)

A tick runs every two hours from 08:00 to 22:00.

1. Read the status block of #201, the `in-progress` issues and the open PRs.
2. If `main` moved since the recorded SHA, inspect the changed behavior and the checks already recorded. Run only relevant missing checks; choose `--all` for a justified broad check. A clean `--current` diff selects only whitespace, so it is not proof of the preceding batch. Fix known build/runtime breakage before new work.
3. For each non-draft PR, resolve actual integration conflicts and missing relevant checks, then merge authorized work or return a concrete failure to its worker. Fetch `main` again after every merge; an advanced base alone does not require repeating sufficient checks.
4. Release stale claims: an `in-progress` issue with no push for 24 hours goes back to `ready`, with a comment.
5. Dispatch `ready` issues up to the caps, using the brief below.
6. Rewrite the status block of #201: on duty, in progress, PRs waiting and why, main's SHA and its last check, next.

Done when every non-draft PR is merged, handed back with a comment, or waiting on a named check; every claim has a push from the last 24 hours or was released; and the status block carries this tick's time. When nothing changed since the last tick, update the time and stop.

## Daily and weekly jobs

- **08:15 brief:** one comment on #201 listing what merged since the last brief, the `needs-monroe` items, the test-when-you-sit-down lists from merged PRs, and today's dispatch plan.
- **18:30 integration:** review the integrated batch and complete relevant missing checks. When batch release/install delivery is authorized, use the checked Release product and verify it with Jot paused and idle. Otherwise record the current usable/source state and remaining delivery step in the next brief.
- **Friday 18:00 hand-off (Codex):** push every claimed branch, comment each claim's next step, and write the weekend queue in #201.
- **Sunday 18:00 hand-off (Claude):** the same, plus the weekly replan: re-rank `ready` work, refresh PLAN.md by PR, and report the week's numbers in #201. Those numbers are issues closed, PRs merged, fix-forwards and reverts, and Monroe's open `needs-monroe` items. Leave no Claude worker running into Monday.

## Worker brief

Give each worker: the issue, the outcome, the files it owns, the sources to read, its blocked-by issues, its allowed actions (branch, push, open a PR, comment on its own issue), the acceptance evidence, and the integration owner, who is the lead on duty.

## Caps

At most 2 Mac workers, 2 cloud workers, and 5 agents running at once. Ask Monroe before going past that.

## Boundaries

These hold for every agent, every tick:

- Leave capture, transcript selection, history, Jot's Application Support folder and its preferences exactly as found. Start or stop capture only for an issue about capture.
- Keep private transcripts, audio and signing credentials on the Mac. Issues, PRs and #201 carry findings and code only.
- Cut public releases only when Monroe says to (see [RELEASING.md](RELEASING.md)).
- Keep repository rules, branch protection and credentials as they are.
- Work only in StoneHub repositories.

## Host setup (once, on the MacBook Pro)

1. Clone Jot, sign in to `gh`, set `JOT_SIGN_IDENTITY` and `JOT_SIGN_TEAM` for the build (`scripts/signing.py`), and confirm `python3 scripts/local-pr-check.py --current` passes.
2. Keep the Mac awake with the Claude and Codex apps open: scheduled runs on both skip while the Mac sleeps. Turn on **Keep computer awake** under **Settings > This computer > System** in the Claude app.
3. **Codex:** open a chat in the Jot project named "Jot lead". Inside it, schedule a task Monday to Friday, every two hours from 08:00 to 22:00, that says: "You are the Jot lead on duty. Run one tick from docs/SWARM.md." Add the 08:15 brief, the 18:30 integration and the Friday 18:00 hand-off the same way. Use a background worktree for Mac workers.
4. **Claude:** in the Code tab, go to **Routines**, then **New routine**, then **Local**, in the Jot folder with the worktree toggle on. Create the same jobs scheduled Saturday and Sunday only, with the Sunday 18:00 hand-off in place of Friday's. For the two-hour weekend cadence, ask Claude in a Desktop session to set the schedule; the picker has no such preset. Click **Run now** once and choose "always allow" for `git`, `gh`, `swift`, `python3 scripts/local-pr-check.py` and `python3 scripts/build-install.py`, so later runs don't stall.
