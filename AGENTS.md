# Jot UI work

Use the Mac's accent color and native Liquid Glass where available. Keep a material fallback for macOS 14–25. Preserve transcript selection, capture state, and local history when replacing the app.

For SwiftUI changes, read `docs/SWIFTUI-FEEDBACK.md` before editing. In Debug, install the feedback overlay and commands, then tag each independently discussable control or row component. Use static labels and opaque per-view instance keys; target metadata must not contain transcript text, speaker names, timestamps, or database IDs. Keep parent tags as well as child tags. Verify a child pick in the installed app without activating its underlying action.

Reusable picker changes belong in the repository recorded in `Vendor/DevFeedback/UPSTREAM.md`. Refresh the vendor snapshot from a committed revision and update that file.

Before sharing an app with another Mac, run `./scripts/build-install.py --configuration Release --build-only`. Its Release checks must pass against the actual product. Keep feedback imports, commands, and key generation behind `#if DEBUG`; Release modifier shims should optimize away metadata. A signed local build is separate from notarization and Gatekeeper distribution proof.
