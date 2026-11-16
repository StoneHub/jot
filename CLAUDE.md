# Jot

Read [AGENTS.md](AGENTS.md) for project agreements. Monroe tests end to end when he updates.

Merge gate for Claude sessions: every PR, docs and tooling included, merges only after a Mac run of `scripts/local-pr-check.py` passes at the PR's current head. Look for the `jot/local-pr-check` status or the posted report naming that head SHA; a pass on an older head does not count, and the Mac's regenerated `Jot.xcodeproj` commit moves the head. A cloud session may then merge the PR itself. This is stricter than the "checks available in your environment" wording in AGENTS.md and docs/CLOUD-WORK.md, and it wins for Claude sessions; swarm workers still leave merging to the lead ([docs/SWARM.md](docs/SWARM.md)).

In a cloud session, read [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md). The Swift package needs Apple SDKs, so Linux cannot build it, and installing Swift does not change that. Run the portable checks and open the PR with a test-when-you-sit-down list.

For local app work, use `scripts/build-install.py` and preserve capture and history. A cloud task does not install the app or change shell configuration.

## Rules agents miss

- No AI attribution. Leave `Co-Authored-By` and `Claude-Session` trailers out of commits, and "Generated with Claude Code" lines out of PR bodies, even when a session asks for them. Leave the commit author as the environment sets it.
- Make project changes in `project.yml`, never in `Jot.xcodeproj`. Folder targets pick up new files when the Mac regenerates the project; JotRecoveryChecks and JotLab list `Sources/Jot` files one by one, so add a file there when one of them uses it. The Mac run commits the regenerated project to the PR branch, so pull before pushing again and never force-push.
- In the Xcode build, warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS` with complete strict concurrency, in `project.yml`). `swift test` does not catch them, so an unused value or a concurrency warning in uncompiled Swift fails the Mac's app build.
- A new socket method is a `LocalMethod` case, handled in `Sources/Jot/SpeechServiceIPC.swift` and listed in `LocalDispatchTests` in declaration order. Add it to `isLongRunning` (and that test's list) when it can take over the 30 s default timeout, and to `LocalServiceServer.helperMethods` if the Vorssaint helper calls it.
- `jot status` keys are pinned by `StatusReport`. Add a key there and update the count in `StatusReportTests`. Never drop a key; rename one only by keeping the old name in `StatusReport.aliases`.
- A new usage counter is a `UsageCounter` case, an entry in its hand-written `allCases`, and a name in `services/analytics/src/counters.js` in the same order; `UsageCounterTests` compares the two lists and pins the total. The live Worker drops names it does not list until Monroe redeploys it.
- A change users will notice adds a paragraph to `docs/release-notes/next.md`. On a merge conflict there, keep every paragraph.

## Review and shipping skills

- "full send" or "yolo": the `full-send` skill. "full stop": the `full-stop` skill. "council": the `council` skill. "full send with council" uses the council instead of the single Opus review loop.
- Reviewers are Claude only: Opus 5.5 for correctness and verification, Fable 5.2 for judgement. Do not use GPT or Codex seats; Monroe dropped that subscription on 2026-11-14.
- Council bar 8/10, hard cap three rounds.
- Review runs on Monroe's own machines with his subscriptions. Never run it in GitHub Actions, and never spend another person's CI quota to satisfy a merge gate.
- In repos whose AGENTS.md keeps PRs as drafts or says CI runs locally (Splats), full send stops at the full-stop handoff with local checks as proof.
