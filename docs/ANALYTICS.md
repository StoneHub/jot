# Anonymous analytics

Jot can send anonymous usage counts so we can see which features people use and where dictation fails. This page is the complete list of what is sent. The receiving service is in [services/analytics](../services/analytics).

## What is sent

Once a local day has finished, Jot sends that day's [usage counters](ACTIVITY.md#usage-counters) in one small JSON request:

```json
{
  "schema": 1,
  "app": "0.3.4",
  "os": "26.1",
  "arch": "arm64",
  "days": [{"day": "2026-10-21", "counters": {"dictation.completed": 12, "insertion.accessibility": 11, "insertion.unverified": 1}}]
}
```

- `app` and `os` are the Jot and macOS version numbers; `arch` is `arm64` or `x86_64`.
- Counter names come only from fixed codes in Jot's source. They describe what happened (a hold finished, text was inserted by Accessibility, a suggestion was taken), never what was said.

## What is never sent

Transcript text, audio, cleaned text, suggestions, field contents, app names or bundle IDs, window titles, speaker names, file paths, your name, your Mac's name or serial, an install ID, or anything typed. The service does not store IP addresses and keeps no row per request, so reports cannot be linked to each other or to a Mac.

## When and how

`UsageReporter` checks a minute after launch and then every six hours. It sends finished local days not yet sent, at most the newest seven and none older than about a month, and skips days with no counts. Each day is sent once. The request is a plain HTTPS POST from an ephemeral session, with no cookies or cache.

Sharing is on by default. Setup says so, and **Settings → Privacy → Share anonymous usage counts** turns it off (`jot settings set shareUsage false` does the same). Days that finish while it is off are never sent, even after it is turned back on. The first run after installing only marks yesterday as done, so a new install's first report is the next day's. Turning sharing off leaves the counters on the Mac for Activity.

Reports go to `UsageReport.endpoint` (`Sources/JotCore/UsageReport.swift`), the Worker deployed from `services/analytics` at `https://jot-analytics.monroesawesome.workers.dev/v1/usage`. Setting it to nil stops all sending.
