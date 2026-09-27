# Jot agreements

Jot is a personal Mac app, and Monroe is its only user. Follow Fleet's development guidance for Mac apps: ship fixes and features fast. Monroe's end-to-end use, when he sits down and updates, is the acceptance test.

## Delivery

- Merge authorized fixes and features to `main` as soon as the checks you can run pass. Do not wait on CI runners, a per-PR `local-pr-check`, reviewers or another session. GitHub Actions stays manual-only.
- On the Mac, run the checks the change touches. `python3 scripts/local-pr-check.py <PR>` picks them from the diff. Then install the merged build with `python3 scripts/build-install.py --configuration Release` and verify it. The installer is capture-safe and needs Jot paused and idle. Ask only if replacing the running app would interrupt Monroe's capture.
- In a cloud session, follow [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md): run the portable checks, say plainly that the Swift is uncompiled, merge, and leave a "test when you sit down" list in the PR.
- Fix forward. When `main` fails to build or the installed app misbehaves, fixing that comes before new work. A small revert is acceptable when the fix is not obvious.
- For pipeline changes, run the real-model `JotRecoveryChecks --audio` path by hand. `local-pr-check` does not cover it.
- For a CPU problem, export `jot diagnostics` before relaunching Jot. Its buffer clears on quit.

These gates do not relax:

- Preserve active capture, transcript selection and local history. Never delete or reset Jot's Application Support folder or preferences to make a task easier, and do not start or stop capture unless the task is about capture.
- Private transcripts, captured audio and signing credentials stay on the Mac.
- Public distribution follows [docs/RELEASING.md](docs/RELEASING.md). It is separate from the installed development app.

## Design

Use the Mac's accent color and native Liquid Glass where available. Keep a material fallback for macOS 14–25.

Jot uses no DevFeedback overlay, commands, or view tags. Keep performance investigation in local reports and CLI diagnostics, outside the product UI, unless Monroe asks for a UI change.

Before sharing an app with another Mac, run `./scripts/build-install.py --configuration Release --build-only`. Its checks must pass against the actual product. A signed local build is separate from notarization and Gatekeeper distribution proof.
