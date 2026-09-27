# Cloud work

Cloud sessions fix known issues and build features without the Mac, then merge. Monroe tests the result end to end when he next updates on his Mac (see [AGENTS.md](../AGENTS.md)). Nothing in cloud work waits on a CI runner or a per-PR Mac check.

## Start here

1. Read `AGENTS.md`, this guide and the issue. Resolve the checkout root with `git rev-parse --show-toplevel` and use repository-relative paths. Personal `/Users/...` paths and the installed app are not cloud dependencies.
2. Run `python3 scripts/cloud-preflight.py`. Preserve existing changes and use the provisioned branch. Check the issue and any overlapping open PR with the host's GitHub tools. If the fix already exists, stop with that evidence.
3. Make the change the issue needs. Expand scope only when a dependency requires it.
4. Run the portable checks below and review your own diff adversarially: uncompiled Swift is only as good as that read.
5. Open the PR, merge it to `main`, and report (see [Return](#return)).

## What Linux can and cannot prove

`Package.swift` includes AppleFM, and JotCore imports AppKit, Darwin and FoundationModels, so **Linux cannot build or test the Swift package**. A failed Apple-framework import is an environment limit. Do not edit the dependency graph or add platform stubs to get around it.

| Work | Cloud proof | Proved later on the Mac |
| --- | --- | --- |
| Python tooling, synthetic JSON scenarios, documentation | Portable checks | Nothing more, unless it feeds the app |
| Swift logic, SwiftUI, AX/event taps, capture/speaker timing, Foundation Models quality | Careful source review; uncompiled | Build, tests, and Monroe's end-to-end use |
| Signing, installation, updater swap, shell integration | None | Local delivery under `AGENTS.md` |

Portable checks:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check-no-feedback.py
python3 scripts/check-suggestion-fixtures.py
git diff --check
```

The signing tests mock signing, the feedback check reads source rather than a built product, and the fixture check validates structure rather than model quality. None of them proves Swift compiles.

## Checking on the Mac

When Monroe sits down to update, a local agent can run the gates a change needs in one go:

```sh
python3 scripts/local-pr-check.py <PR> --dry-run   # show the gates the diff needs
python3 scripts/local-pr-check.py <PR> --post      # run them and post the report on the PR
python3 scripts/local-pr-check.py --current        # check the current checkout, such as main after a batch
```

The script fetches into its own worktree, `work/pr-<PR>`, and picks gates from the changed paths:

| Gate | Runs when the diff touches | Command |
| --- | --- | --- |
| Portable | always | the portable checks above |
| Swift tests | `Sources/`, `Tests/`, `Package.*` | any `--filter` tests first, then `swift test` |
| App build | `Sources/`, `Resources/`, `project.yml`, `Jot.xcodeproj/`, `Package.*`, build/signing scripts | `scripts/build-install.py --build-only` (Debug; no install) |
| Recovery checks | `Sources/Jot/`, `Sources/JotCore/`, the recovery-check scripts, `project.yml`, `Package.*` | build and run `JotRecoveryChecks` with a fresh `CFFIXED_USER_HOME` |

`--all` runs every gate, and `--skip <gate>` omits one. The verdict is `PASS` (exit 0), `FAIL` (1) or `INCOMPLETE` (3). Logs and reports go to `work/pr-checks/`. The script never installs or merges, and it does not cover interactive UI, Accessibility, physical Fn, installed-app, updater or live-capture behavior; that is Monroe's end-to-end test. It is a diagnostic tool, not a merge gate. When it finds a break on `main`, fix forward.

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

Merge the PR, then report once:

- The issue, the PR URL and the merged commit on `main`.
- What changed and why, with the file list.
- The commands actually run and their results, and plainly what did not run (for example, "Swift uncompiled").
- A short "test when you sit down" list in the PR: what to try on the Mac, and what would show it is broken.

Do not poll runners, schedule check-ins or wait for Mac validation after merging.
