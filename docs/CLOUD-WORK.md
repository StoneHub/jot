# Efficient cloud work

Use a cloud runner for a bounded repository task with known checks. Prove the environment once, then spend the session on the assigned outcome. This guide prepares work; it does not launch runners, enable integrations, spend credits, or authorize the backlog wholesale.

## Start here

1. Read `AGENTS.md`, this guide and the assigned issue/task packet. Resolve the checkout root with `git rev-parse --show-toplevel`; use repository-relative paths. Personal `/Users/...` paths and installed Mac apps are not cloud dependencies. This guide contains the scoped cloud handoff; do not spend a session searching for inaccessible personal guidance.
2. Run `python3 scripts/cloud-preflight.py`. Record commit, platform and dirty state. Preserve existing changes. Use the provisioned task branch; respect the host's branch restrictions rather than fighting its prefix. Confirm the assigned issue and overlapping PRs through the host's GitHub tools or `gh`.
3. Run the packet's available baseline checks once. Save full logs outside version control; quote only the relevant failing excerpt and preserve the command's exit status. A check that cannot run is unavailable, not passed.
4. Make the smallest change meeting the acceptance criteria. Use exact files/symbols from the packet before expanding search. Expand only when a dependency requires it. No incidental cleanup, dependency upgrades or whole-repo rearchitecture.
5. Run affected checks and review the diff. Deliver a commit/PR with evidence and any remaining Mac gate. The local integrator owns final review, required Mac checks, merge, canonical checkout and any separately authorized install.

If the issue is closed, the fix already exists, or a PR overlaps the same change, stop with that evidence instead of duplicating it. Read-only planning packets end with their artifact; code packets end with a scoped PR ready for the next validation gate.

## Jot's actual environment boundary

At preparation baseline `47b757a`, `Package.swift` includes AppleFM; JotCore contains AppKit, Darwin and FoundationModels imports. Consequently **Linux cannot run the current complete `swift test` graph**. A failed Apple-framework import is an environment limit, not a reason to edit the production dependency graph or scatter platform stubs through the app.

| Work | Cloud lane | Proof still needed |
| --- | --- | --- |
| Synthetic JSON scenarios, stdlib Python tooling, documentation | Portable, independently testable | First actual runner preflight; local integration review |
| Narrow Swift logic patch with an explicit acceptance test | Source preparation, if the task allows uncompiled work | Mac Swift tests and affected app build before merge |
| SwiftUI, AX/event taps, Foundation Models quality, capture/speaker timing | Mac-dependent; cloud can do bounded analysis or prepare a patch | Actual Apple SDK/runtime and often interactive or recorded-audio evidence |
| Signing, installation, updater swap, real shell integration | Local delivery | Correct artifact/identity and authorized capture-safe installation |

Available portable checks:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check-no-feedback.py
git diff --check
```

The existing five Python tests mock signing operations. Their success does not mean an app is signed or Swift works. Source feedback checks do not validate a built product. During preparation these commands passed on the Mac; a hosted Linux rehearsal has not been performed.

For the local integrator, `python3 scripts/cloud-preflight.py --require-macos` checks tool presence only. Then check the PR as below. For an authorized delivery, follow `AGENTS.md` and `scripts/build-install.py`; the cloud worker cannot claim installed behavior. Private transcripts, captured audio and signing credentials remain on the Mac.

## Local check of a cloud PR

From any Jot checkout on the Mac:

```sh
python3 scripts/local-pr-check.py <PR> --dry-run   # show the gates the diff needs
python3 scripts/local-pr-check.py <PR> --post      # run them and post the report on the PR
```

The script fetches the PR into its own worktree, `work/pr-<PR>`, without switching or editing the current checkout. It picks gates from the changed paths:

| Gate | Runs when the diff touches | Command |
| --- | --- | --- |
| Portable | always | `git diff --check`, `scripts/test_*.py`, `check-no-feedback.py`, `check-suggestion-fixtures.py` when present |
| Swift tests | `Sources/`, `Tests/`, `Package.*` | any `--filter` tests first, then `swift test` |
| App build | `Sources/`, `Resources/`, `project.yml`, `Jot.xcodeproj/`, `Package.*`, build/signing scripts | `scripts/build-install.py --build-only` (Debug; no install) |
| Recovery checks | `Sources/Jot/`, `Sources/JotCore/`, the recovery-check scripts, `project.yml`, `Package.*` | build and run `JotRecoveryChecks` with a fresh `CFFIXED_USER_HOME` |

`--all` runs every gate, and `--skip <gate>` omits one. The verdict is `PASS` (exit 0), `FAIL` (1) or `INCOMPLETE` (3). A skipped gate, or one that is unavailable on this machine, makes the result INCOMPLETE. Logs and `report.md`/`report.json` are written to `work/pr-checks/pr-<PR>-<commit>/`, with the home directory replaced by `~`. The report carries `<!-- jot-local-check verdict=... head=<full commit> -->`, so it applies only to that commit; a new push needs a new report. The script never installs, approves or merges. It does not cover interactive UI, Accessibility, physical Fn, installed-app, updater or live capture behavior, or manual checks the PR lists.

GitHub does not let an account approve its own PR, so for PRs opened under the owner's account the approval is a PASS report posted from that account. Merge when the latest owner report is PASS for the current head, the PR's manual review items are done, and no later owner comment reports a problem. A watching cloud session may merge on that signal. After merge, installation still follows `AGENTS.md`.

Copy-ready prompt for a local agent:

> Check Jot PR #N. From the Jot checkout, run `python3 scripts/local-pr-check.py N --dry-run`, then `python3 scripts/local-pr-check.py N --post --note "<what you reviewed>"`. Before posting, do the manual review items in the PR description and summarize them in the note. If a gate fails, investigate in `work/pr-N`. For a small fix within the PR's scope, commit there, push with the command the script prints, and run the check again. Otherwise post the failing evidence and the fix you propose. Do not install or merge unless Monroe asks, and leave the canonical checkout and capture alone.

## Stop environment loops early

Use a five-minute preflight limit for the first pilot. Allow one evidence-backed corrective action for a missing declared dependency or transient network failure. If the same class of failure recurs, report the blocker and the smallest required change; continue only independent work already allowed by the packet.

- Missing Apple SDK on Linux: take the declared portable/source-only lane. Do not install Xcode, emulate macOS or rewrite the app for Linux.
- Registry/network denial: record the exact needed host and failing command; request that host in the environment configuration. Repeating the same download or disabling TLS does not fix an allowlist.
- Missing authentication: use the host's GitHub tools first; never print environment variables/tokens or enter an interactive login loop. Preserve a patch if remote write is unavailable and label it unsubmitted.
- Missing personal MCP service, installed Jot or `/usr/bin/fm`: use the synthetic/mocked path in the packet. Actual model evaluation is a separate Mac task, not a call to a cloud substitute.
- Failed test present before edits: distinguish it from the task regression. Repair only if in scope; otherwise record it and the impact on verification.
- Large or stuck output: keep logs, preserve exit codes and inspect the failing section. Avoid piping a test through `head` and accidentally treating the pipeline as a pass.

Do not change manifests, lockfiles, production guardrails or tests just to make an unsupported runner look green. If implementation itself remains uncertain after two distinct failed fixes, checkpoint the hypothesis and failing evidence for the coordinator rather than beginning an unbounded rewrite.

## Environment setup and cost controls

As documented September 25, Anthropic-hosted setup runs on Ubuntu 24.04, before the agent. Its filesystem result is cached; running processes are not. Put reusable tool installation in environment setup and repo/version-dependent checks in a short session preflight. For the first Jot portable task, Git and Python are enough; leave setup empty if they are present. Install from declared manifests/lockfiles for other repos. Do not launch unnecessary databases or services. See [cloud environments](https://code.claude.com/docs/en/cloud-environments).

Cloud runners do not automatically inherit personal settings, local files or local MCP servers. Push task documents and fixture inputs before launch. Prefer a clean remote checkout; inspect the selected launch mode rather than assuming a local worktree is what the runner receives. See [cloud task setup and handoff](https://code.claude.com/docs/en/claude-code-on-the-web).

Start one small pilot and measure actual usage and useful output before increasing concurrency. One worker per task; no automatic agent teams, recurring runs or PR auto-fix loops for the pilot. Choose a capable standard coding model for bounded work and escalate reasoning only when the task needs it. Keep the task's launch settings in its dispatch record, not permanent repo defaults. A fresh task packet should contain the relevant state rather than the entire planning conversation. Follow the [cost guidance](https://code.claude.com/docs/en/costs), but verify account billing separately from estimates.

For API-backed CLI print-mode runners, the documented `--max-budget-usd` and `--max-turns` flags can bound a run. Verify them with that installed CLI's help and set them in the launcher. They are **print-mode controls**, not an assumed cap on a managed web session; writing a dollar limit into a prompt is not enforcement. Set account/service controls appropriate to the actual credit type, record their scope, and monitor the pilot. See [CLI reference](https://code.claude.com/docs/en/cli-reference). This repository does not contain personal credit balances or account settings.

## Dispatch and return contract

Copy one task packet, assign one issue, and name its lane. Before dispatch, record the base commit, model/effort, budget enforcement if available, expected file ownership, and local integration owner. Merge dependencies before starting dependent tasks. Parallel work is appropriate only for independent files/contracts; avoid two workers editing a central service at once.

Return:

- Issue and branch/PR URL, base and final commit.
- What changed and why, with the scoped file list.
- Commands actually run, results and pre-existing failures.
- Explicit unavailable checks, remaining runtime proof, and the local check command (`python3 scripts/local-pr-check.py <PR>`, with any `--filter` tests the packet names).
- Any deviations, environment blocker, and measured usage if the runner exposes it.

The worker does not merge a code PR whose declared Mac gate is still pending. This is a division of responsibility: the local integrator completes the authorized delivery after validation.

## Initial queue

For the named companion projects and copy-ready prompts, see the [personal repository cloud queue](cloud-tasks/portfolio.md).

| Task packet | Priority/lane | Boundary |
| --- | --- | --- |
| [Suggestion evaluation fixtures](cloud-tasks/suggestion-fixtures.md), part of [#79](https://github.com/StoneHub/jot/issues/79) | First portable pilot | Create synthetic evidence and validation tooling; no app/engine implementation or live model run |
| [Export paragraph pause](cloud-tasks/export-paragraph-pause.md), [#73](https://github.com/StoneHub/jot/issues/73) | Small source patch followed by Mac validation | One formatting bug; no settings overhaul or changed tuning range |
| [#75](https://github.com/StoneHub/jot/issues/75), Regroup/speaker-pass ordering | Prefer Mac | Concurrency regression needs the real harness and lifecycle |
| [#72](https://github.com/StoneHub/jot/issues/72), CPU sample intervals | Prefer Mac | Darwin resource accounting and measured interval proof |
| [#58](https://github.com/StoneHub/jot/issues/58), settings consolidation; [#63](https://github.com/StoneHub/jot/issues/63), threading | Split before dispatch | Broad shared files and integration risks make poor first pilots |

For each additional personal repo, first identify its manifest/lockfile, exact focused test command, required OS/hardware, declared services, network hosts, secrets boundary and one existing issue. Run its baseline in the intended runner once. Then write a packet with acceptance criteria and ownership. Do not perform a broad account/repository scan or include excluded work repositories.
