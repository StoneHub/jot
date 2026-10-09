# Swarm

A swarm of agents works Jot's issue queue. Two leads take turns over one shared state, and short-lived workers each take one issue.

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
2. Work on that branch in its own worktree. For a behavior change, show red/green: the new test fails with only the fix reverted. Cloud workers follow [CLOUD-WORK.md](CLOUD-WORK.md).
3. Review: one adversarial reviewer. Use three lenses when the change moves work across threads or rewrites stored data.
4. Open the PR with `Fixes #N`, the checks you ran and their results, what you couldn't run, and a short **test when you sit down** list for Monroe.

Done when the PR is open and marked ready for review, and the claim comment links it. Merging belongs to the lead.

## Merge rule

The lead on duty merges, one PR at a time, when `python3 scripts/local-pr-check.py <PR> --post` reports `PASS` on the PR head with current `main` merged in. `--post` also publishes the verdict as the `jot/local-pr-check` status on the PR head. A PASS covers the gates the diff needs: portable checks, Swift tests, the app build and the recovery checks.

The `app-behavior` and real-model-audio attestations aren't merge gates. They go on Monroe's daily test list, and a failure he finds is fixed forward. Workers, cloud ones included, open PRs and leave merging to the lead.

## Tick (lead on duty)

A tick runs every two hours from 08:00 to 22:00.

1. Read the status block of #201, the `in-progress` issues and the open PRs.
2. If `main` moved since the SHA in the status block by anything other than a merge you made on PASS, run `python3 scripts/local-pr-check.py --current --all` from a clean checkout of `main`. Without `--all`, a clean checkout runs only the portable gate. If it fails, fixing main is this tick's only work.
3. For each non-draft PR: if it's behind `main`, merge `main` into it and push. Run the check, then `gh pr merge <PR> --merge` on PASS, or comment the failure and hand the PR back to its worker. Fetch `main` again after every merge.
4. Release stale claims: an `in-progress` issue with no push for 24 hours goes back to `ready`, with a comment.
5. Dispatch `ready` issues up to the caps, using the brief below.
6. Rewrite the status block of #201: on duty, in progress, PRs waiting and why, main's SHA and its last check, next.

Done when every non-draft PR is merged, handed back with a comment, or waiting on a named check; every claim has a push from the last 24 hours or was released; and the status block carries this tick's time. When nothing changed since the last tick, update the time and stop.

## Daily and weekly jobs

- **08:15 brief:** one comment on #201 listing what merged since the last brief, the `needs-monroe` items, the test-when-you-sit-down lists from merged PRs, and today's dispatch plan.
- **18:30 integration:** run `python3 scripts/local-pr-check.py --current --all` on a clean checkout of `main`. On PASS, install with `python3 scripts/build-install.py --configuration Release`, but only when Jot on the host is paused and idle. Otherwise skip the install and say so in the next brief.
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
