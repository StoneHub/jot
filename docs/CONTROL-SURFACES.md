# Local control surfaces and Vorssaint

Jot stays a standalone app. A host such as Vorssaint's Dynamic Island can show and change Jot's listening state through the local control API below, while Jot keeps capture, history and insertion. A host is always optional.

## Control API

`jot controls` / `speech.controls` returns a small presentation snapshot without reading history. Version 1, the default, contains `version`, `mode`, `meetingActive`, optional `dictation`, `dictationSequence`, `suggestion`, `suggestionSequence`, and `inputLevel` (finite 0–1). Dictation states use `DictationAttempt.State`; suggestions use the existing outcome codes. Sequences are process-local counters, not session or transcript identifiers. Treat a reconnection as a fresh baseline; never replay an old completion animation.

A caller that sends `{"version": 2}` gets `version: 2` and, each only when it has a value, `meetingStartedAt` (ISO 8601 UTC, whole seconds; when the running meeting began, kept through automatic pauses) and `notice` (a `ControlNotice` code, never Jot's notice text). The codes are `models.loading`, `meeting.start-failed`, `meeting.exporting`, `meeting.end-failed`, `meeting.saved-in-parts`, `meeting.exported-uncleaned`, `meeting.stopped`, `paused.sleep`, `microphone.changed`, `microphone.stopped` and `other`; a reader must accept codes it does not know. Without `version`, the reply is byte-for-byte version 1, so `jot controls` and `jot listen` are unchanged. Any other `version` is an error.

Jot posts `space.jot.app.controlsChanged` through DistributedNotificationCenter when shortcut, listening, meeting, dictation or suggestion state changes. This carries no object or payload. It is an invalidation hint, never authoritative state or a command. Read the existing same-user Unix socket to get the snapshot; poll conservatively to recover from missed hints and refresh microphone levels only during a visible active action. Notifications do not need to be enabled to use the endpoint.

Controllers use the existing `speech.pause`, `speech.resume`, `speech.meeting_start` and `speech.meeting_end` methods. Starting capture remains an explicit user action. Opening `/Applications/Jot.app` raises the app through its existing reopen handler. An Island can mirror Fn activity, but must keep Jot's field-anchored suggestion preview and explicit Tab insertion. A delivery-unverified state must never be presented as confirmed insertion. No controller should subscribe to transcripts merely to animate a microphone.

## Vorssaint feature shipped in Jot.app

Integrations fit the host's existing feature discovery, settings and lifecycle rather than a plugin loader or a separately branded Jot utility. Jot.app carries its own Vorssaint feature: `Contents/Resources/VorssaintIntegration.json` declares the Jot row, the Listening switch and its actions, and `Contents/Helpers/jot-vorssaint` answers the host one JSON line per request. A Vorssaint build with native app features finds it in /Applications after checking Jot's signature, and consent is bound to that signature and declaration, so turn the feature on again after either changes. Stock Vorssaint does not have the native app-feature catalog yet.

The helper reads only `speech.controls` and `speech.preview` and calls the controller methods above, so no title or audio reaches the host, and transcript text only as the opt-in preview below. Jot's socket enforces this: when a peer's executable is this app's `Contents/Helpers/jot-vorssaint`, `LocalServiceServer` answers only those six methods (`helperMethods`) and refuses the rest. After Listen, Don't listen and the meeting actions it reads again, for up to three seconds, until Jot shows the requested state, so the switch does not flip back. The Listening switch requests pause immediately without a confirmation dialog; pause also ends an active meeting. The mapping lives in `VorssaintPresentation` with its tests.

Each host request carries `version` 1 or 2, and the reply carries the same version. Version 2 replies add `startedAt` (ISO 8601 UTC, while a meeting runs) and `notice` (the code above, while Jot shows a notice). Version 1 replies are unchanged.

### Transcript preview

With General → App → "Share transcript preview" on (`shareTranscriptPreview`, default on), version 2 replies also carry `preview`: the newest row Jot saved while listening, on one line, at most 180 characters including a `Name: ` speaker prefix when Jot knows the name; a longer row keeps its newest words after a leading `…`. It is absent while paused, during a hold-only dictation, before the listening session's first row, and with the setting off. Dictation is never previewed. The helper reads it from `speech.preview`, which `LocalServiceServer` answers only for the bundled helper (`helperOnlyMethods`); every other peer, including the jot CLI, is refused. `speech.preview` returns `{"enabled": Bool, "preview"?: String}`. A new row posts the change hint while the setting is on. The host must show the preview as text only, never act on it, and never store or log it; the helper keeps nothing.

## Standalone menu bar fallback

Jot works independently of any external controller. Its General → App setting, “Always show menu bar icon”, defaults on. When off, Jot hides its icon only while Vorssaint runs Jot's bundled `jot-vorssaint` helper, which it does only while its Jot feature is on. Jot checks at launch, observes macOS application launch/termination notifications, and, while the setting is off, reconciles every three seconds to recover missed events and notice Vorssaint switching its Jot feature on. Its icon returns if the controller quits or crashes and hides again when the controller relaunches. This runtime fallback does not change the saved preference or start/stop capture. Vorssaint with the Jot feature off and unrelated apps do not suppress Jot's icon.

Focused native regression: `swiftc -swift-version 6 -parse-as-library Sources/Jot/JotControllerPresence.swift Tests/JotMenuBarChecks/ControllerPresenceChecks.swift -o build/controller-presence-checks && build/controller-presence-checks`.

## Try when at the Mac

- With “Always show menu bar icon” off, turn Vorssaint's Jot feature off and on: Jot's icon should return and then hide. Launch Jot with no controller running: its icon should appear. With the setting on, the icon should stay visible throughout.
- Hold Fn: the Island should show capture, then processing on release, then the actual insertion result. Check a failed or unverified insertion shows review rather than success.
- Double-Fn: the preview stays beside the field; Tab accepts and Escape dismisses. Opening or observing a controller must not start capture.
- Pause/Resume and Start/End Meeting through the Island; confirm the microphone and meeting state in Jot agree. Confirm connection loss removes stale controls.
