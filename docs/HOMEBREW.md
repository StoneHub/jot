# Homebrew

Jot ships a Homebrew cask in [`Casks/jot.rb`](../Casks/jot.rb). This repository doubles as its tap, so no separate `homebrew-*` repository is needed.

## Install

```sh
brew tap stonehub/jot https://github.com/StoneHub/jot
brew install --cask stonehub/jot/jot
```

Tapping clones this repository. The explicit URL is required because the repository is not named `homebrew-jot`. If your Homebrew asks you to trust the tap before a cask can run its install step, run `brew trust stonehub/jot` first. That step is the `postflight` block below, and it runs nothing else.

Jot updates itself (**Models & updates**, plus the daily check in **General → Privacy**). The cask says `auto_updates true`, so `brew upgrade` leaves Jot alone and Homebrew's recorded version can lag behind the app. `brew uninstall --cask jot` removes `/Applications/Jot.app` only. The cask has no `zap` stanza, so transcripts, voices and settings stay in `~/Library/Application Support/Jot` and Jot's preferences.

Requirements match the ZIP: Apple silicon and macOS 14 or later.

## Until releases are notarized

Every release so far is a `--local` pre-release, signed with a development certificate and not notarized ([RELEASING.md](RELEASING.md#local-pre-releases)). That means:

- **Homebrew's own cask repository will not take Jot.** Since 2026-09-01 it disables casks that fail Gatekeeper, and `--no-quarantine` is gone. That is why the cask lives in this repository's tap.
- **The cask clears the quarantine flag itself.** `postflight` runs `xattr -dr com.apple.quarantine` on the installed app, which is what Jot's updater already does after it checks the signing team. Without it, the first launch stops at "cannot verify the developer".
- **It still runs only where the development build runs.** Clearing quarantine skips the Gatekeeper prompt; it does not make a development-signed build valid on every Mac. Treat the cask as a convenience for testers until the first notarized release.

Once a release is notarized and stapled (Developer ID certificate for team `N6GPP46885` plus `JOT_NOTARY_PROFILE`), delete the `postflight` block. Gatekeeper then accepts the download as it is. The cask could also be submitted to `homebrew/cask` once Jot meets its notability rules.

## How the cask stays current

`scripts/release.py` rewrites `version` and `sha256` in `Casks/jot.rb` to the final ZIP's values. That change goes into the same `Release X.Y.Z` commit as the version bump, and `--dry-run` restores the file with everything else. The URL is derived from `version` and points at the release asset `Jot-<version>.zip`, the same asset the in-app updater downloads. If publishing fails after the release commit is pushed, the cask points at a missing asset until the release is published.

To check a cask edit on a Mac:

```sh
cd ~/Developer/jot && brew style Casks/jot.rb && brew audit --cask --tap stonehub/jot jot
```
