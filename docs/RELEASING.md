# Releasing Jot

## Local releases

Releases are cut on Monroe's Mac with `scripts/release.py`; it is the only machine with the signing identity, and the app is signed with an Apple Development certificate, not notarized. That is deliberate: macOS permissions follow the code signature, so every update must be signed with the same identity and installed at `/Applications/Jot.app`. The in-app updater strips the quarantine flag itself, so Gatekeeper never sees the unnotarized download.

```sh
python3 scripts/release.py patch --notes "What changed" --install
```

`patch`, `minor`, `major`, or an explicit `X.Y.Z` picks the new version. The script, one printed line per step:

1. Refuses unless it is on `main`, the tree is clean, `HEAD` equals `origin/main` after a fetch, `gh auth status` passes, and a signing identity is set.
2. Bumps `JotVersion.current`, `project.yml`, and `Resources/Info.plist`. `CFBundleShortVersionString` is the version; `CFBundleVersion` is the number of existing `v*` tags plus one, so it increases every release. Writes `docs/RELEASE-NOTES-<version>.md` from `--notes`.
3. Runs `swift test`, then `build-install.py --configuration Release --build-only`, and reads `build/release-proof.json`.
4. Zips the product with `ditto -c -k --sequesterRsrc --keepParent` to `build/Jot-<version>.zip` and writes `build/Jot-<version>.zip.sha256`.
5. Commits `Release <version>`, creates the annotated tag `v<version>` with the notes as its message, pushes `main --follow-tags`, and runs `gh release create` with the zip and checksum. The asset must be named `Jot-<version>.zip`; the updater asks for exactly that name.
6. With `--install`, runs `build-install.py --configuration Release` so the same product lands in `/Applications`.

`--dry-run` stops after step 4, prints what it would commit, tag, and publish, and restores the tree.

Local builds and releases default to Monroe's Apple Development identity and team `N6GPP46885`. The scripts never select the first certificate in the keychain. `JOT_SIGN_IDENTITY` can select a renewed certificate; the built product must still belong to Monroe's team. Build and install proof record the verified team.

If an older local installation was signed by a different team, pause capture and run `python3 scripts/build-install.py --configuration Release` once. This preserves local history and backs up the old app. macOS may require permissions again after the signing change. The in-app updater continues to reject cross-team updates.

## Notarized distribution (not in use)

Publish from the default branch after required checks pass. Keep public distribution separate from the installed development app.

1. Confirm a clean checkout, current `origin/main`, no required unmerged work, and an unused version tag matching `JotVersion.current` in `Sources/JotCore/JotVersion.swift`, `Resources/Info.plist`, and `project.yml`.
2. Run `swift test` and `./scripts/build-install.py --configuration Release --build-only`. The script resolves the actual Xcode product, verifies the owner signing team and signatures, rejects DEBUG and feedback artifacts, and writes `build/release-proof.json`.
3. Confirm the product contains `ThirdPartyNotices.txt`, no private transcripts, audio recordings, credentials, or development reports. Review README screenshots for private content. Models download separately on first use.
4. Create a ZIP with `ditto -c -k --sequesterRsrc --keepParent` from the resolved app. Submit it using `xcrun notarytool submit` with an authorized keychain profile and wait for Accepted. Never put credentials into the repository or release logs.
5. Run `xcrun stapler staple` and `xcrun stapler validate` on the app, then `codesign --verify --deep --strict` and `spctl --assess --type execute --verbose=4`. All must pass. Recreate the ZIP after stapling and compute its SHA-256 checksum.
6. Create the version tag at the verified default-branch commit and a GitHub release with the final ZIP, checksum, requirements, privacy behavior, and release notes. Verify the uploaded download checksum. Do not publish an unnotarized candidate as the finished release.

## First release status

The initial version is 0.1.0 (build 1). Developer ID signing is available. On September 9, 2026, Gatekeeper rejected the candidate as `Unnotarized Developer ID`; no notarization profile was found in the configured user keychains or credential environment. An authorized notarization credential for the signing team is required before publishing. No version tag or public binary release was created at that checkpoint.
