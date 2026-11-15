# Jot

Read [AGENTS.md](AGENTS.md) for project agreements, including how to ship: merge fixes and features once a Mac run of `local-pr-check` passes. Monroe tests end to end when he updates.

In a cloud session, read [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md). The Swift package requires Apple SDKs, and installing Swift on Linux does not make it buildable. Run the portable checks, open the PR with the Mac test list, and leave the merge to a Mac session.

For local app work, use `scripts/build-install.py` and preserve capture and history. A cloud task does not install the app or change shell configuration.

## Review and shipping skills

- "full send" or "yolo": the `full-send` skill. "full stop": the `full-stop` skill. "council": the `council` skill. "full send with council" uses the council instead of the single Opus review loop.
- Reviewers are Claude only: Opus 5.5 for correctness and verification, Fable 5.2 for judgement. Do not use GPT or Codex seats; Monroe dropped that subscription on 2026-11-14.
- Council bar 8/10, hard cap three rounds.
- Review runs on Monroe's own machines with his subscriptions. Never run it in GitHub Actions, and never spend another person's CI quota to satisfy a merge gate.
- In repos whose AGENTS.md keeps PRs as drafts or says CI runs locally (Splats), full send stops at the full-stop handoff with local checks as proof.
