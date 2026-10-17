# Cloud work

Cloud sessions fix known issues and build features without the Mac. [AGENTS.md](../AGENTS.md) governs proportional checks and solo delivery: merge authorized work after the relevant checks available in the environment pass, and report native work that remains uncompiled or untested. No dedicated runner or GitHub App is needed for the optional local checker.

## Start here

1. Read `AGENTS.md`, this guide and the issue. Resolve the checkout root with `git rev-parse --show-toplevel` and use repository-relative paths. Personal `/Users/...` paths and the installed app are not cloud dependencies.
2. Run `python3 scripts/cloud-preflight.py`. Preserve existing changes and use the provisioned branch. Check the issue and any overlapping open PR with the host's GitHub tools. If the fix already exists, stop with that evidence.
3. Make the change the issue needs. Expand scope only when a dependency requires it.
4. Run the affected portable checks below and review your own diff: uncompiled Swift is only as good as that read. Widen checks for affected boundaries, failures or unresolved risk.
5. Save authorized work remotely using the agreed integration owner and workflow, then report (see [Return](#return)). Use a PR when coordination needs one; native checks and Monroe's device use remain explicit follow-up evidence.

## What Linux can and cannot prove

`Package.swift` includes AppleFM, and JotCore imports AppKit, Darwin and FoundationModels, so **Linux cannot build or test the Swift package**. A failed Apple-framework import is an environment limit. Do not edit the dependency graph or add platform stubs to get around it.

| Work | Cloud proof | Proved later on the Mac |
| --- | --- | --- |
| Python tooling, synthetic JSON scenarios, documentation | Portable checks | Native gate publication itself still needs Mac validation; nothing more for standalone documentation/tooling unless it feeds the app |
| Swift logic, SwiftUI, AX/event taps, capture/speaker timing, Foundation Models quality | Careful source review; uncompiled | Build, tests, and Monroe's end-to-end use |
| Signing, installation, updater swap, shell integration | None | Local delivery under `AGENTS.md` |

A new, renamed or removed source file goes in `project.yml` only. `Jot.xcodeproj/project.pbxproj` is xcodegen output, and xcodegen assigns its own IDs, so a hand edit never matches what it generates and leaves the Mac check `INCOMPLETE` on a dirty tree. Say in the PR that the project needs regenerating; the Mac run commits the regenerated file to the PR branch before its final check.

Portable checks follow the changed behavior. Documentation needs `git diff --check`; changed Python tooling runs its matching existing test file. For example, a local-checker change uses:

```sh
python3 -m unittest discover -s scripts -p 'test_local_pr_check.py'
git diff --check
```

`local-pr-check` selects the relevant tooling tests and guards. The signing tests mock signing, the feedback check reads source rather than a built product, and the fixture check validates structure rather than model quality. None proves Swift compiles. Use all portable tests only when affected tooling boundaries or an explicit broad check warrant them.

## Checking on the Mac

When a Mac is available, a local agent can run the diagnostic gates a change needs in one go:

```sh
python3 scripts/local-pr-check.py <PR> --dry-run   # show the gates the diff needs
python3 scripts/local-pr-check.py <PR> --post      # run them and post the report on the PR
python3 scripts/local-pr-check.py --current        # check the current checkout, such as main after a batch
```

The script fetches into its own worktree, `work/pr-<PR>`, and picks gates from the changed paths:

| Gate | Runs when the diff touches | Command |
| --- | --- | --- |
| Portable | whitespace always; tooling tests/guards for their changed inputs | the affected portable checks above |
| Swift tests | package sources, `Tests/`, `Package.*`, or explicit `--filter` | only the requested filters; otherwise `swift test` |
| App build | `Sources/`, `Resources/`, `project.yml`, `Jot.xcodeproj/`, `Package.*`, build/signing scripts | `scripts/build-install.py --build-only` (Debug; no install) |
| Recovery checks | core/engine sources, runtime app owners, recovery/capture scripts and build inputs | build and run `JotRecoveryChecks` with a fresh `CFFIXED_USER_HOME` |

Presentation files select an app build without the generic recovery harness or package tests. Unknown app files retain recovery coverage. The selector's current file groups live in `scripts/local-pr-check.py`; widen the plan when a presentation edit changes runtime behavior. `--filter` runs only requested tests; `--all` selects every gate and the full suite once, including all portable tests/guards. `--skip <gate>` omits one. The verdict is `PASS` (exit 0), `FAIL` (1) or `INCOMPLETE` (3). A diagnostic `PASS` means only the selected gates passed. Logs and full reports stay in `work/pr-checks/`; optional `--post` sends a fixed summary and publishes the verdict as `jot/local-pr-check`, without raw logs, machine details or manual-check details. The script never installs or merges and does not automatically test interactive UI, Accessibility, physical Fn, installed-app, updater or live capture. Fix forward when `main` breaks.

Base fetch failures stop validation rather than reuse stale refs. The checked worktree must remain clean at the exact head, with checks before/after each command and gate; live PR head/base changes invalidate the run. A cancelled, invalidated or uncertain publication rewrites the local report as `INCOMPLETE`. Public comments are sent only after terminal status verification when status publication is requested. A dirty `--current` checkout is diagnostic-only and yields `INCOMPLETE` if its checks otherwise pass. By default, a PR whose fork metadata is unavailable cannot execute checks. After reviewing its code, `--allow-fork` explicitly allows a fork or unknown-provenance diagnostic run; missing metadata still prevents publication. `--no-gh --dry-run` can inspect a plan without executing PR code.

### Opt-in native status

This optional broad evidence mode is not a routine merge gate. Use a trusted checker and existing, already-authorized `gh` credentials. Review PR-controlled scripts, tests and build inputs before executing them with the Mac's ambient access. The checker does not create credentials, install an App, change repository settings, or prove branch protection is enforced.

```sh
python3 scripts/local-pr-check.py <PR> --publish-status --ui-attestation /path/to/local-attestation.json
```

`--publish-status` is separate from `--post`, forces all four gates, and requires a PR with verified GitHub metadata. It cannot use `--current`, `--no-gh`, `--skip` or `--dry-run`. It first publishes `pending` in the fixed `jot/local-macos-validation` context, then `success` only when the PR head contains the current base, every gate passes on macOS, and all required manual attestations match the full head and base SHAs. An advanced or divergent base blocks status publication until the branch is updated and revalidated; ordinary diagnostic checks explicitly label outdated-base results as head-only evidence. Failed checks publish `failure`; missing native tools/coverage/attestations or a cancelled/invalidated run publish `error` when publication remains available. API failures are reported as incomplete and are not automatically retried.

For any app-affecting diff (the app-build triggers above), record `app-behavior`: the actual affected UI and runtime paths exercised, including interruption/repetition where relevant, and any manual checks listed in the PR. A change in the selected recovery footprint also requires `real-model-audio`, recording the separate `JotRecoveryChecks --audio <local-audio-file>` check. The default recovery gate uses synthetic audio and does not supply this proof. These entries are a person's explicit attestations, not automated UI-test results. Standalone docs and test-only changes need no UI attestation; this optional publication mode still runs all four native gates.

Keep the JSON outside tracked files, and fill it only after performing the checks on the exact revision:

```json
{
  "head": "<full checked PR head SHA>",
  "baseHead": "<full freshly fetched base SHA>",
  "reviewer": "<person who actually performed the checks>",
  "checks": {
    "app-behavior": {"result": "passed", "details": "<affected paths actually exercised and observed>"},
    "real-model-audio": {"result": "passed", "details": "<actual real-model recovery check and outcome>"}
  }
}
```

Omit a check only when the diff does not require it. Missing, skipped, failed, malformed or stale attestations cannot produce a successful native status. Never put private transcripts, audio, credentials or raw logs into a PR or status; the attestation's details stay local.

Head/base/worktree are freshly rechecked before publication and again after success; a detected publication-time race revokes success with `error`. Status publication requires the current base to be an ancestor of the tested head. GitHub commit status writes do not offer an atomic head/base condition. Statuses bind to the head SHA and their descriptions record the full tested base SHA, so a later base update requires renewed validation, and the authorized merger must verify the current head/base evidence immediately before merging. Requiring this context and an up-to-date branch in repository rules is a separate, explicitly authorized setup step. This code alone does not enforce a GitHub merge restriction.

## Stop environment loops early

Give the preflight about five minutes and allow one evidence-backed fix for a missing declared dependency or a transient network failure. If the same class of failure recurs, report the blocker and the smallest required change.

- Missing Apple SDK on Linux: take the source-only lane. Do not install Xcode, emulate macOS or rewrite the app for Linux.
- Registry or network denial: record the exact host and failing command, and request that host in the environment configuration. Repeating the download or disabling TLS does not fix an allowlist.
- Missing authentication: use the host's GitHub tools. Never print environment variables or tokens. If remote write is unavailable, preserve a patch and label it unsubmitted.
- Missing personal MCP service, installed Jot or `/usr/bin/fm`: use a synthetic or mocked path. Real model evaluation happens on the Mac.
- A test failing before your edits: tell it apart from your change. Fix it if it is in scope; otherwise record it.
- Large or stuck output: keep logs and exit codes. Do not pipe a test through `head` and mistake the pipeline's status for a pass.

Do not change manifests, lockfiles, production guardrails or tests to make an unsupported runner look green.

## Environment

Anthropic-hosted setup runs on Ubuntu before the agent; Git and Python are all the portable checks need. Cloud sessions do not inherit personal settings, local files or local MCP servers. See [cloud environments](https://code.claude.com/docs/en/cloud-environments) and [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web).

## Return

After the reviewed, tested branch is published, report once:

- The issue, commit or PR URL, revision, and integration state; name the integration owner when one is assigned.
- What changed and why, with the file list.
- The commands actually run and their results, and plainly what did not run (for example, "Swift uncompiled").
- A short test-when-you-sit-down list in the issue or PR: affected manual paths, relevant unavailable checks, and what would show a failure.

Describe portable checks as portable evidence and uncompiled Swift plainly. Follow the authorized integration and delivery finish line; paid runners, repository protections and credentials keep their own authority.
