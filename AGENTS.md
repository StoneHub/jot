# Jot agreements

Jot is a personal Mac app, and Monroe is its only user. Merge authorized fixes and features once the affected build and meaningful behavioral checks available in your environment pass. Monroe's end-to-end use when he updates is the acceptance test.

## Delivery

- Choose the smallest checks that expose a failure in the changed behavior. Use focused tests and the affected build, with representative UI interaction when relevant; broaden for affected integration boundaries, failures or unresolved risk. Keep tests for history, privacy, field insertion and audio loss. When touching an area, prune superseded code, fixtures, tests and instructions after checking current consumers; retain compatibility for an identified consumer or migration.
- `scripts/build-install.py` cleans Xcode intermediates automatically in linked worktrees and exports only the verified app under `build/products`; `--disposable-build` requests the same behavior in the ordinary checkout. The ordinary checkout otherwise retains its one development cache. Preserve running exported products.
- Keep commits small and recoverable. Use a PR or isolated worktree when coordination or repository rules need it. GitHub Actions stays manual-only; merge authorized work without waiting on runners, per-PR device validation or a mandatory reviewer. Leave a short test-when-you-sit-down list in the issue or PR and say plainly which relevant checks could not run. A portable pass does not prove native behavior.
- `python3 scripts/local-pr-check.py <PR>` is optional diagnostic tooling that selects checks from the diff. `--filter TEST` runs only those Swift tests; `--all` requests every gate and the full suite. For cloud work or optional status publication, read [docs/CLOUD-WORK.md](docs/CLOUD-WORK.md). Statuses and manual attestations are evidence, not standing merge requirements.
- When installation or release is requested, deliver the checked Release product and verify it using [docs/RELEASING.md](docs/RELEASING.md). Batch delivery rather than rebuilding each intermediate change. The installer needs Jot paused and idle; ask only if replacing the running app would interrupt capture. Tooling/documentation changes need no app installation.
- **Swarm:** when you lead or work the swarm queue (claiming an issue, running a tick, a hand-off), follow [docs/SWARM.md](docs/SWARM.md).
- Fix forward. When `main` fails to build or the installed app misbehaves, fixing that comes before new work. A small revert is acceptable when the fix is not obvious.
- For recognition, speaker or cleanup changes, choose a relevant local real-model audio comparison when model quality needs evidence; `local-pr-check`'s synthetic recovery does not prove accuracy. Keep private audio local.
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
