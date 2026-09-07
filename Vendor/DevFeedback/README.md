# DevFeedback for SwiftUI

Pick a tagged view in a native Mac development build, describe the requested change, and export selected notes with stable target IDs and source locations. Porch Speech is the first integration. This prototype is separate from the browser extension and is not a published Swift package release.

## Add to an app

Requires macOS 14+, Swift tools 5.9, and a Debug build. Add this directory as a local Swift package dependency and link the **DevFeedback** product to the app target. For a reproducible host checkout, vendor this directory without `.build`/`.swiftpm`, preserve the license, and record the exact upstream repository commit. SwiftPM cannot fetch a nested package by repository URL; a dedicated package repository can follow after the integration proves useful.

```swift
import SwiftUI
#if DEBUG
import DevFeedback
#endif

// Inside the App's scene builder:
Window("My App", id: "main") {
    #if DEBUG
    StatusView().feedbackOverlay(appID: "example.app", screen: "status")
    #else
    StatusView()
    #endif
}
.commands {
    #if DEBUG
    FeedbackCommands()
    #endif
}

// At the meaningful control or section boundary:
Button("Save", action: save)
    .feedbackTarget("profile.save", label: "Save profile")
```

The tag example assumes the package is imported. Hosts that guard the import in Release can provide a Release-only no-op tagging shim with lazy (`@autoclosure`) arguments, or conditionally compile tag calls. Verify the resulting distributable, including dynamic tag-key creation, rather than relying on the shim alone.

The idle overlay inserts no button, badge, or reserved spacing. Activate **Developer → Pick UI for Feedback** or **⌘⌥⇧F** while the app window is active. **Developer → Feedback History…** opens saved notes. Highlight outlines and Cancel appear only during an active pick. Targets report their actual layout bounds using anchor preferences; nested picking chooses the smallest registered bounds under the pointer. Add `.feedbackViewport()` to each `ScrollView` itself (outside its content) or other clipped container. Outlines and click hit-testing then use only the intersection with every enclosing viewport; offscreen targets are omitted from the visible count. Capture context retains the original bounds. Container tags preserve descendant tags. Register a row/card and its independently discussable mode label, timestamp, text body, and actions; a lone container tag cannot provide granular feedback. Repeated components need distinct non-sensitive instance IDs. Labels should be static developer text, never values from a transcript, document, or form. The default `#fileID` and `#line` identify the tagging call, not a guaranteed permanent source location.

The screen parameter may change with navigation: new captures use the current screen while saved records and open drafts preserve their original screen. History is shared within the app ID. Install an overlay separately on any sheet needing capture. Release builds compile both public modifiers as inlinable no-ops with lazy metadata arguments, omit the Developer menu items, and exclude the panel, store, and record implementation. The Release test confirms metadata-producing expressions are not evaluated. Host and dependency must both use Debug; a host-only flag does not enable the Release package.

## Test the workflow

1. With the app window active, press **⌘⌥⇧F** or choose **Developer → Pick UI for Feedback**. Orange outlines show registered targets. Click a control; its normal action should not execute.
2. Write a requested change and optional acceptance checks. **Save & pick next** returns to the picker; **Save** returns to History. Cancel picking with Escape or Cancel.
3. Close and reopen the panel with an unsaved draft, then navigate to a different app section. The draft should stay attached to its original target. Save or explicitly discard before another pick.
4. Edit a saved note. Its original target, capture time, bounds, appearance, and app/build stay unchanged.
5. Select records and **Review export**. Copy Markdown or save JSON. Confirm unselected notes are excluded. Notes themselves can contain private information.
6. **Show in Finder** reveals the exact local history JSON. Moving it to Trash clears stored history; reopening the feedback panel reloads disk state. An in-progress draft remains in memory until discarded or saved. Files already exported and clipboard copies are independent.

## Storage and export

History lives under the host's Application Support directory in `DevFeedback/<hex-encoded-app-ID>/history.json`. Saves are atomic, limited to 500 records with 16,000 characters per request/acceptance field. Unsupported or corrupt history is preserved and reported rather than reset. Opening the panel refreshes disk state; same-process main-thread window saves merge the current file. Simultaneous writes from separate app processes are not supported.

The package stores only static registered metadata, window-local bounds, screen, appearance, app/build version, notes, and acceptance checks. It does not inspect rendered text, record audio, or capture screenshots. It adds no network, Accessibility, microphone, or Screen Recording access. Sandboxed hosts need user-selected read/write file access for the save dialog; unsandboxed development apps need no additional entitlements.

JSON has `schemaVersion: 1`, `source: "swiftui-dev-feedback"`, and `records`. Each record has `id`, `createdAt`, `appID`, `screen`, `target` (`id`, `label`, `file`, `line`), `bounds`, `appVersion`, `build`, `appearance`, `note`, and `acceptance`. Dates use Foundation Codable's seconds since 2001-01-01 UTC. The selected snapshot is captured before the save dialog opens.

Agents can read this JSON or the Markdown with ordinary file tools. Browser MCP import compatibility, screenshots, native menu/title-bar picking, untagged-view discovery, and iOS are outside this first slice. Bounds and source hints describe capture time; agents must resolve them against current source. Rendered UI coverage still requires manual verification.

## Agent companion

The repository includes a [Codex plugin](../../plugins/swiftui-feedback/README.md) with integration/tag-maintenance instructions and a duplicate literal-ID checker. It is packaged source for local testing, not a published marketplace listing. Installing the agent plugin and linking the app library are separate steps.

## Checks

```sh
swift test --package-path packages/swiftui-feedback
swift test -c release --package-path packages/swiftui-feedback
```

Tests include an actual SwiftUI hosting/rendering regression for nested parent/child registrations, plus persistence, selected-only export, edits preserving context, failed writes, corrupt/future history, field limits, same-process windows, and Finder deletion. The host integration must also exercise the real picker, panel, and export dialog.

## Distribution gate

Development installation and a distributable are distinct products. Use Xcode **Release** for Archive/export; never distribute the Debug app used for feedback. Check effective host and package compilation conditions: `DEBUG` must be absent. Verify the built app has no Developer feedback commands, picker, History panel/storage code, bundled DevFeedback framework/resources, source hints, or feedback-only tag markers. Inspect the actual linked executable and bundle, and fail packaging if markers remain. Importing a dependency in the project is not by itself proof that its runtime ships, nor is hiding a control proof of exclusion. Signing and notarization are separate host release requirements.
