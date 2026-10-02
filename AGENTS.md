# Jot agreements

Jot is a personal Mac app, and Monroe is its only user. Follow Fleet's development guidance for Mac apps: ship fixes and features fast, with evidence for the exact revision. Native-unvalidated app changes stay unmerged. Monroe's end-to-end use complements native build and test validation.

## Delivery

- Publish authorized fixes and features as draft PRs after the available checks and independent review pass. Merge only with merge authorization and the required validation for the current head and base. GitHub Actions stays manual-only; a portable pass is not a native pass.
- On the Mac, `python3 scripts/local-pr-check.py <PR>` picks diagnostic checks from the diff. The opt-in `--publish-status` mode runs all four gates and publishes `jot/local-macos-validation` using existing `gh` credentials, with explicit SHA/base-bound manual attestations when required (see the cloud guide). It never installs, approves or merges. Only after an authorized merge, install with `python3 scripts/build-install.py --configuration Release` and verify it. The installer is capture-safe and needs Jot paused and idle. Ask only if replacing the running app would interrupt Monroe's capture.
- In a cloud session, follow [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md): run the portable checks, say plainly what remains uncompiled or untested, and leave native-unvalidated changes unmerged with a specific Mac validation list in the PR.
- Fix forward. When `main` fails to build or the installed app misbehaves, fixing that comes before new work. A small revert is acceptable when the fix is not obvious.
- For pipeline changes, run the real-model `JotRecoveryChecks --audio` path by hand. `local-pr-check` does not cover it.
- For a CPU problem, export `jot diagnostics` before relaunching Jot. Its buffer clears on quit.

These gates do not relax:

- Preserve active capture, transcript selection and local history. Never delete or reset Jot's Application Support folder or preferences to make a task easier, and do not start or stop capture unless the task is about capture.
- Private transcripts, captured audio and signing credentials stay on the Mac.
- Run a trusted checker and review PR-controlled scripts/tests before executing them with local credentials. The published status is validation evidence, not a sandbox or proof that GitHub requires it. Repository rules and credential setup are separate decisions; do not change them as part of a code fix.
- Public distribution follows [docs/RELEASING.md](docs/RELEASING.md). It is separate from the installed development app.

## Design

Use the Mac's accent color and native Liquid Glass where available. Keep a material fallback for macOS 14–25.

Jot uses no DevFeedback overlay, commands, or view tags. Keep performance investigation in local reports and CLI diagnostics, outside the product UI, unless Monroe asks for a UI change.

Before sharing an app with another Mac, run `./scripts/build-install.py --configuration Release --build-only`. Its checks must pass against the actual product. A signed local build is separate from notarization and Gatekeeper distribution proof.
