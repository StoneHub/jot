# Jot's Homebrew cask. It lives in the app's repository, so this repository is also the tap; see docs/HOMEBREW.md.
# scripts/release.py rewrites version and sha256 in each release commit, so the cask always names the newest ZIP.
cask "jot" do
  version "0.3.5"
  sha256 "ff3c17c50922ff3e8e001b5db357341f2beb8f68e4733341812dd6f4170098da"

  url "https://github.com/StoneHub/jot/releases/download/v#{version}/Jot-#{version}.zip"
  name "Jot"
  desc "Local dictation and ambient transcripts"
  homepage "https://github.com/StoneHub/jot"

  # Jot's own updater replaces /Applications/Jot.app, so brew upgrade leaves it to that.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Jot.app"

  # Releases are not notarized yet, so Gatekeeper would block the first launch. Like Jot's updater, clear the
  # quarantine flag only after the signature meets Jot's code requirement (an Apple-issued certificate for team
  # N6GPP46885, the same as AppUpdater.officialRequirement); otherwise warn and keep Gatekeeper's check.
  # Install steps take literal arguments only, so the verify-then-clear branch runs in sh: $1 is the
  # requirement and $2 the installed app.
  postflight_steps do
    run "/bin/sh",
        args:           [
          "-c",
          'if /usr/bin/codesign --verify --deep --strict -R="$1" "$2"; then ' \
          '/usr/bin/xattr -dr com.apple.quarantine "$2"; ' \
          'else echo "Jot does not meet the code requirement for team N6GPP46885; ' \
          'macOS will ask before the first launch." >&2; fi',
          "jot-cask",
          'anchor apple generic and certificate leaf[subject.OU] = "N6GPP46885"',
          "{{appdir}}/Jot.app",
        ],
        writable_paths: ["Jot.app"],
        writable_base:  :appdir
  end

  caveats <<~EOS
    Jot releases are not notarized yet. The cask checks the signature and
    signing team, then clears the quarantine flag so Jot opens without the
    Open Anyway prompt. Builds signed for development may not open on every
    Mac until notarized releases ship.
  EOS

  # No zap stanza: Jot's folder in Application Support holds transcripts and voices,
  # which uninstalling must never delete.
end
