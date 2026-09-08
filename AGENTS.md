# Jot UI work

For authorized Jot changes, default to merging the scoped PR after required checks pass, then install and verify the merged version locally. Do not stop at an unmerged branch unless Monroe asks. Preserve active capture and history; public distribution remains separate.

Use the Mac's accent color and native Liquid Glass where available. Keep a material fallback for macOS 14–25. Preserve transcript selection, capture state, and local history when replacing the app.

Jot uses no DevFeedback overlay, commands, or view tags. Keep performance investigation in local reports and CLI diagnostics, outside the product UI, unless Monroe asks for a UI change.

Before sharing an app with another Mac, run `./scripts/build-install.py --configuration Release --build-only`. Its checks must pass against the actual product. A signed local build is separate from notarization and Gatekeeper distribution proof.
