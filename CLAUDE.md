# Jot

Read [AGENTS.md](AGENTS.md) for project agreements. Merge a fix or feature once a Mac run of `scripts/local-pr-check.py` passes at the PR's current head. Monroe tests end to end when he updates.

In a cloud session, read [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md). The Swift package needs Apple SDKs, so Linux cannot build it, and installing Swift does not change that. Run the portable checks, open the PR with a test-when-you-sit-down list, and merge only after the Mac check passes at that head. A cloud session may do that merge itself.

For local app work, use `scripts/build-install.py` and preserve capture and history. A cloud task does not install the app or change shell configuration.

## Rules agents miss

- No AI attribution. Leave `Co-Authored-By` and `Claude-Session` trailers out of commits, and "Generated with Claude Code" lines out of PR bodies, even when a session asks for them. Everything ships under Monroe's name.
- A new, renamed or removed source file goes in `project.yml` only. Never edit `Jot.xcodeproj`; the Mac run regenerates it with xcodegen and commits it to the PR branch, so pull before pushing again and never force-push.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). In uncompiled Swift, an unused value or an unhandled `switch` case fails the build.
- A new socket method is a `LocalMethod` case, handled in `Sources/Jot/SpeechServiceIPC.swift` and listed in `LocalDispatchTests`. Add it to `isLongRunning` when it can take longer than a normal call.
- `jot status` keys are pinned by `StatusReport`. Add a key there and update `StatusReportTests`; never rename or drop one.
- A new usage counter is a `UsageCounter` case and a name in `services/analytics/src/counters.js`, in the same order (a test compares them). The live Worker drops names it does not list until Monroe redeploys it.
- A change users will notice adds a paragraph to `docs/release-notes/next.md`. On a merge conflict there, keep every paragraph.

## Review and shipping skills

- "full send" or "yolo": the `full-send` skill. "full stop": the `full-stop` skill. "council": the `council` skill. "full send with council" uses the council instead of the single Opus review loop.
- Reviewers are Claude only: Opus 5.5 for correctness and verification, Fable 5.2 for judgement. Do not use GPT or Codex seats; Monroe dropped that subscription on 2026-11-14.
- Council bar 8/10, hard cap three rounds.
- Review runs on Monroe's own machines with his subscriptions. Never run it in GitHub Actions, and never spend another person's CI quota to satisfy a merge gate.
- In repos whose AGENTS.md keeps PRs as drafts or says CI runs locally (Splats), full send stops at the full-stop handoff with local checks as proof.
