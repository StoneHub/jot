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
  depends_on macos: ">= :sonoma"

  app "Jot.app"

  # Releases are not notarized yet, so Gatekeeper would refuse the first launch. Jot's updater clears the same flag
  # on every update after checking the signing team; this does it once for the copy Homebrew installed.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Jot.app"]
  end

  # No zap stanza: Jot's folder in Application Support holds transcripts and voices, which uninstalling must never delete.
end
