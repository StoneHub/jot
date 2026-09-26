# Personal repository cloud queue

Prepared 2026-09-25 for repository-based cloud sessions. The initial queue below is historical: its first batch produced eight merged PRs plus a reviewed ThreadSpace design. See [the next batch](next-batch.md) for current assignments and local acceptance evidence. Each repository carries its own setup/task instructions so a runner does not need this whole planning conversation or another local checkout.

## Initial sequence (completed or superseded)

| Order | Repository / task | Expected result | Environment boundary |
| --- | --- | --- | --- |
| 1 | [Jot #81](https://github.com/StoneHub/jot/issues/81) | Synthetic suggestion scenarios and validator | Git + Python; no Swift build or real transcripts |
| 2 | [AppleFM VS Code #17](https://github.com/StoneHub/apple-fm-vscode/issues/17) | Real Provider request-rule tests with mocked backend/editor | Node, Python, Ruby 3.1+; no Mac helper packaging |
| 3 | [Jev design](https://github.com/StoneHub/jev-tab-organizer/blob/main/docs/TAB-TRIAGE.md) | Keep/save/close interaction, saved links and personal-context design | Source review; existing tests use Node 22+ and zip |
| 4 | [ThreadSpace #26](https://github.com/benwilliams0540/t3code/issues/26) | Source-backed path to shared conversation, project context and agent work | Review first; no full monorepo setup, live server or credentials |
| 5 | [Terminal #10](https://github.com/StoneHub/apple-fm-terminal/issues/10) | Bounded decision report on invalid Git completions | Source review; optional fake-model suite requires zsh/Expect and PTY |
| Later | [Jot #73](https://github.com/StoneHub/jot/issues/73) | Small export-formatting patch | Cloud can prepare source; Mac tests/build required |

Order is a recommendation, not a requirement to serialize independent work. Start one implementation pilot, inspect measured usage and the resulting diff, then increase concurrency only for independent scopes. A design review may run alongside an implementation task once the pilot is understood. Do not ask one worker to fix this entire table.

## Dependency map

Jot pins the personal [AppleFM Swift library](https://github.com/StoneHub/apple-fm-swift) in `Package.swift`, `Package.resolved` and `project.yml`. Its framework serves generic on-device inference; Jot owns contextual retrieval and suggestions. The terminal and VS Code repos are companion clients, not current Jot package dependencies. Updating their main branches does not upgrade Jot's pin. FluidAudio is an external pinned dependency; this plan does not assign changes to its upstream.

AppleFM Swift's [cloud guide](https://github.com/StoneHub/apple-fm-swift/blob/main/docs/CLOUD-WORK.md) deliberately assigns no speculative implementation. Review it when a concrete caller requirement needs a framework change. Linux Swift cannot supply FoundationModels.

## Launch prompts

Choose the target repository in the hosted runner and use one prompt:

**Jot**

> Implement issue #81. Read CLAUDE.md and docs/cloud-tasks/suggestion-fixtures.md. Run the preflight and portable baseline once, execute only that packet, and return one scoped PR with actual validation evidence and remaining gates.

**VS Code**

> Implement issue #17 using docs/CLOUD-WORK.md. Test the real Provider with mocked editor, backend and timers. Run the baseline once, then focused checks and npm test. Stop repeated environment failures and return one scoped PR. Do not package or run live inference.

**Jev**

> Explore the tab-triage product brief in docs/TAB-TRIAGE.md using docs/CLOUD-WORK.md. Recommend a concrete keep/save/close experience, a useful saved-link list, and the smallest personal-context model. Produce the design and at most three testable implementation slices. Do not implement yet.

**ThreadSpace**

> Review issue #26 and its Cloud design review packet. Assess the smallest useful Discord-plus-T3 experience from current source: shared conversation, files/project context and attributed agent work. Challenge architecture where evidence warrants it. Return a source-backed design and at most three implementation slices. This task is review only; follow the packet's repository-access and environment boundaries.

## Model and spending decisions

Use a capable coding model for the two bounded implementation tasks. Use the stronger model the user selects in the actual launcher for the Jev/ThreadSpace design reviews; record the exact selectable model and effort with the run. A model name in a prompt does not configure the launcher, and a mentioned or unavailable model name must not be silently substituted.

For an independent second opinion, give the reviewer the same brief and source anchors, then compare recommendations against their evidence. Commission a second review only if the first leaves a consequential decision unresolved. Do not fund two broad repo tours merely to get two opinions.

Set any available credit/spending controls in the actual service before launch; prompt budgets are not enforced caps. Keep account balances, private runner details and private repository evidence out of public docs. Measure the pilot's actual usage before assigning a larger batch. For preparation/stop/return rules see [the Jot cloud guide](../CLOUD-WORK.md).

## Evidence so far

The first batch has now had Mac integration. Jot passed 187 Swift tests, 35 Python tests, signed build and recovery checks; its Release executable is installed and hash-verified. Jev passed 15 tests and isolated Chromium smoke; loading the unpacked extension into the user profile remains manual. VS Code and Terminal have separate installed/runtime acceptance records. ThreadSpace delivered reviewed documentation, not a new runtime. See the next-batch handoff for precise links and remaining gates.
