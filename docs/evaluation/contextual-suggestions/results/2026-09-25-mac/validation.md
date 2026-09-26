## Local check: PASS

<!-- jot-local-check verdict=PASS head=a6c32b2b3c0fe7b11685b6a5e7032ece94850950 pr=87 -->

PR #87: head `a6c32b2` on `stonework/gallant-heisenberg-0oow2r`; base `main`, merge base `784a125`.
Machine: macOS 27.2 (arm64), Python 3.9.6, Xcode 27.0, Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1).

| Gate | Result | Time | Why it ran |
| --- | --- | --- | --- |
| Portable checks | passed | 3 s | always |
| Swift package tests | passed | 5 s | requested |
| Signed Debug app build (no install) | passed | 3 s | app sources, resources or build configuration changed |
| JotRecoveryChecks (fresh CFFIXED_USER_HOME) | passed | 22 s | service, store or recovery-check sources changed |

Commands:

- portable: `git diff --check 784a12587cf5ffcdcb63ad68fc7f1c9e075fa91f a6c32b2b3c0fe7b11685b6a5e7032ece94850950`
- portable: `/Applications/Xcode.app/Contents/Developer/usr/bin/python3 -m unittest discover -s scripts -p test_*.py`
- portable: `/Applications/Xcode.app/Contents/Developer/usr/bin/python3 scripts/check-no-feedback.py`
- portable: `/Applications/Xcode.app/Contents/Developer/usr/bin/python3 scripts/check-suggestion-fixtures.py`
- swift-test: `swift test --filter SuggestionEvaluation`
- swift-test: `swift test`
- app-build: `/Applications/Xcode.app/Contents/Developer/usr/bin/python3 scripts/build-install.py --build-only`
- recovery-checks: `xcodegen generate`
- recovery-checks: `xcodebuild -project Jot.xcodeproj -scheme JotRecoveryChecks -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath build/DerivedData.noindex -clonedSourcePackagesDirPath build/SourcePackages build`
- recovery-checks: `build/DerivedData.noindex/Build/Products/Debug/JotRecoveryChecks`

Changed files (13): `Package.swift`, `Sources/JotSuggestionEvaluation/Corpus.swift`, `Sources/JotSuggestionEvaluation/EvaluationRun.swift`, `Sources/JotSuggestionEvaluation/ModelCallGate.swift`, `Sources/JotSuggestionEvaluation/SourceSelection.swift`, `Sources/JotSuggestionEvaluation/SuggestionEvaluationCommand.swift`, `Sources/JotSuggestionEvaluation/SuggestionPrompt.swift`, `Tests/JotSuggestionEvaluationTests/EvaluationFixture.swift`, `Tests/JotSuggestionEvaluationTests/SuggestionEvaluationRunTests.swift`, `Tests/JotSuggestionEvaluationTests/SuggestionEvaluationSelectionTests.swift`, `docs/evaluation/contextual-suggestions/README.md`, `scripts/check-suggestion-results.py`, `scripts/test_suggestion_results.py`

Not covered by this script: interactive UI, Accessibility and physical Fn behavior; installed-app, updater and live capture behavior; manual checks the PR description lists.
