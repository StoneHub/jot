# Jot's Homebrew cask. It lives in the app's repository, so this repository is also the tap; see docs/HOMEBREW.md.
# scripts/release.py rewrites version and sha256 in each release commit, so the cask always names the newest ZIP.
cask "jot" do
  version "0.3.4"
  sha256 "2d783b8f2b5679f654031e665b9ca888b965fc54ff00f44f9b6a03e3bc5d61bd"

  url "https://github.com/StoneHub/jot/releases/download/v#{version}/Jot-#{version}.zip"
  name "Jot"
  desc "Local dictation and ambient transcripts"
  homepage "https://github.com/StoneHub/jot"

  # Jot's own updater replaces /Applications/Jot.app, so brew upgrade leaves it to that.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Jot.app"

  # Releases are not notarized yet, so Gatekeeper would block the first launch. Like Jot's updater, clear the quarantine
  # flag only after the signature verifies and names Jot's team; anything else keeps Gatekeeper's check.
  postflight do
    app = "#{appdir}/Jot.app"
    # The requirement ties the team to an Apple-issued leaf certificate; AppUpdater.officialRequirement is the same.
    requirement = 'anchor apple generic and certificate leaf[subject.OU] = "N6GPP46885"'
    verify = system_command("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", "-R=#{requirement}", app])
    if verify.success?
      system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", app]
    else
      opoo "Jot's signature does not meet the requirement for team N6GPP46885; macOS will ask before the first launch."
    end
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
