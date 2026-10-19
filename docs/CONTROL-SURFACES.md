# Local control surfaces

`jot controls` / `speech.controls` returns a small presentation snapshot without reading history. It contains `version` (currently 1), `mode`, `meetingActive`, optional `dictation`, `dictationSequence`, `suggestion`, `suggestionSequence`, and `inputLevel` (finite 0–1). Dictation states use `DictationAttempt.State`; suggestions use the existing outcome codes. Sequences are process-local counters, not session or transcript identifiers. Treat a reconnection as a fresh baseline; never replay an old completion animation.

Jot posts `space.jot.app.controlsChanged` through DistributedNotificationCenter when shortcut, listening or suggestion state changes. This carries no object or payload. It is an invalidation hint, never authoritative state or a command. Read the existing same-user Unix socket to get the snapshot; poll conservatively to recover from missed hints and refresh microphone levels only during a visible active action. Notifications do not need to be enabled to use the endpoint.

Controllers use the existing `speech.pause`, `speech.resume`, `speech.meeting_start` and `speech.meeting_end` methods. Starting capture remains an explicit user action. Opening `/Applications/Jot.app` raises the app through its existing reopen handler. An Island can mirror Fn activity, but must keep Jot's field-anchored suggestion preview and explicit Tab insertion. A delivery-unverified state must never be presented as confirmed insertion. No controller should subscribe to transcripts merely to animate a microphone.

## Integration principles

Jot stays useful as a standalone app. Integrations should fit the host app's existing feature discovery, settings and lifecycle, use this reusable local control API, and keep capture, history and insertion owned by Jot. A host remains optional. The Vorssaint contribution is an opt-in built-in feature, rather than a plugin loader or separately branded Jot utility app.

## Standalone menu bar fallback

Jot works independently of any external controller. Its General → App setting, “Always show menu bar icon”, defaults on. When off, Jot hides its icon only while Vorssaint runs Jot's bundled `jot-vorssaint` helper, which it does only while its Jot feature is on, or while the retired custom Vorssaint+Jot app (`space.monroe.JotBar`) is running. Jot checks at launch, observes macOS application launch/termination notifications, and reconciles every three seconds to recover missed events. Its icon returns if the controller quits or crashes and hides again when the controller relaunches. This runtime fallback does not change the saved preference or start/stop capture. Vorssaint with the Jot feature off and unrelated apps do not suppress Jot's icon.

Focused native regression: `swiftc -swift-version 6 -parse-as-library Sources/Jot/JotControllerPresence.swift Tests/JotMenuBarChecks/ControllerPresenceChecks.swift -o build/controller-presence-checks && build/controller-presence-checks`.

## Try when at the Mac

- With “Always show menu bar icon” off, turn Vorssaint's Jot feature off and on: Jot's icon should return and then hide. Launch Jot with no controller running: its icon should appear. With the setting on, the icon should stay visible throughout.

- Hold Fn: the external controller should show capture, then processing on release, then the actual insertion result. Check a failed or unverified insertion shows review rather than success.
- Double-Fn: the preview stays beside the field; Tab accepts and Escape dismisses. Opening or observing a controller must not start capture.
- Pause/Resume and Start/End Meeting through the controller; confirm the microphone and meeting state in Jot agree. Confirm connection loss removes stale controls.
