# Handoff: use the tuned pause in Markdown exports

## Goal

When assigned issue #73, make Markdown export use the same effective paragraph pause as Sessions, with a focused regression test and a small PR.

## Current state

Start at the runner's clone root on its provisioned task branch; record `git status --short` and commit. Preparation baseline: `47b757a`. In that baseline, `TranscriptExport.markdown` calls continuation folding and paragraph merging with default thresholds. The app's Sessions path uses `host.tuning.bounded.paragraphPause`.

Issue #73 says “3 s,” but the current setting and slider are capped at 2.5 s. Use a supported nondefault value such as 2.4 s and a separating gap between 1.5 and 2.4 s for the regression. Verify the bound at the task's actual base. Do not widen the setting range as part of this export fix.

## Required context

Read `AGENTS.md`, `docs/CLOUD-WORK.md`, the live issue #73, then these exact paths:

- `Sources/JotCore/TranscriptExport.swift`
- `Sources/JotCore/TranscriptionTuning.swift` (`TranscriptGrouping` is in this file)
- `Sources/Jot/SessionLibrary.swift` (Sessions grouping and file export)
- `Sources/Jot/SpeechServiceIPC.swift` (Markdown socket export)
- `Tests/JotCoreTests/TranscriptExportTests.swift`
- `Tests/JotCoreTests/TranscriptGroupingTests.swift`

On Linux this is a source-preparation task. The complete Swift graph requires Apple SDKs. The local integrator owns compile/test/build and merge; missing frameworks do not authorize portability refactors.

## Next steps

1. Run the portable preflight and baseline; verify #73 is open and no overlapping PR already fixes it. Read only the paths above, then follow relevant callers with `rg`.
2. Add a regression covering two same-speaker rows with a gap that stays separate under the default and joins at the supported larger pause. Compare exported paragraph grouping with the Sessions grouping pipeline. Preserve speaker, session and mode boundaries and the default behavior of callers that omit tuning.
3. Carry the effective tuning through both file and socket Markdown exports. Apply it consistently to continuation folding and paragraph merging where those pipelines use the pause. Leave JSON exports, unrelated settings, titles and naming behavior intact.
4. Review all `TranscriptExport.markdown` and `.write` callers for compilation and default compatibility. Keep changes to the identified API, callers and focused tests.
5. On a compatible Mac, run `swift test --filter TranscriptExportTests` and `swift test --filter TranscriptGroupingTests`; on Linux report those commands as unavailable without running a known-impossible build. Run the portable checks and `git diff --check` on either platform.
6. Submit a scoped PR linked to #73 with exact evidence and the pending Mac checks. Do not merge until the integrator validates the code and affected app build.

## Verification

The Mac integrator runs the focused tests above, any affected caller tests, then the appropriate app build to catch source outside the Swift package. Runtime acceptance compares Sessions and Markdown at a supported nondefault pause. Use synthetic data; no user's history or capture changes. Preserve actual output and test counts.

## Risks and stop conditions

Do not turn this into settings consolidation (#58), a transcript database change or a Linux port. A Python script that imitates the Swift algorithm cannot prove the Swift patch. Keep the cloud result labelled uncompiled when applicable. Follow the guide's environment retry bound; return the patch and remaining gate rather than spending tokens on Xcode installation.
