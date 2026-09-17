# Releasing Jot

## Local releases

Official releases are cut on Monroe's Mac with `scripts/release.py`. They require a Developer ID Application certificate for owner team `N6GPP46885`, hardened runtime, and Apple notarization. Every official update uses that team so installed permissions and the updater's signature check remain stable.

```sh
python3 scripts/release.py patch --notes "What changed" --install
```

`patch`, `minor`, `major`, or an explicit `X.Y.Z` picks the new version. The script, one printed line per step:

1. Refuses unless it is on `main`, the tree is clean, `HEAD` equals `origin/main` after a fetch, `gh auth status` passes, and a signing identity is set.
2. Bumps `JotVersion.current`, `project.yml`, and `Resources/Info.plist`. `CFBundleShortVersionString` is the version; `CFBundleVersion` is the number of existing `v*` tags plus one, so it increases every release. Writes `docs/RELEASE-NOTES-<version>.md` from `--notes`.
3. Runs `swift test`, then `build-install.py --configuration Release --build-only`, and reads `build/release-proof.json`.
4. Zips the product, submits it to Apple with `notarytool`, and waits for `Accepted` before continuing.
5. Staples and validates the notarization ticket, verifies the signature and Gatekeeper assessment, then recreates `build/Jot-<version>.zip` and its checksum from the stapled app.
6. Commits `Release <version>`, creates the annotated tag `v<version>` with the notes as its message, pushes `main --follow-tags`, and runs `gh release create` with the zip and checksum. The asset must be named `Jot-<version>.zip`; the updater asks for exactly that name.
7. With `--install`, runs `build-install.py --configuration Release` so the same product lands in `/Applications`.

## Local pre-releases

Until the Developer ID certificate and notarization credentials exist, `--local` publishes a release signed with the installed development identity:

```sh
python3 scripts/release.py patch --notes "What changed" --local --install
```

It runs the same steps without notarization and marks the GitHub release as a pre-release. The in-app updater accepts it: it strips the quarantine flag and requires the download's TeamIdentifier to match the running app, so the build installs on Macs that trust that development certificate and nowhere else.

`--dry-run` verifies the owner certificate, tests and builds the app, creates an unstapled candidate ZIP, prints the remaining notarization and publication work, and restores the tree without submitting or publishing.

Local source builds use the developer's own installed signing identity. On Monroe's Mac they prefer his Apple Development identity. `JOT_SIGN_IDENTITY` and `JOT_SIGN_TEAM` select another installed identity. Build and install proof record the verified team.

Official releases are stricter: `release.py` accepts only a Developer ID Application certificate for `N6GPP46885` and requires `JOT_NOTARY_PROFILE`, the name of credentials stored with `xcrun notarytool store-credentials`. It submits the ZIP, waits for `Accepted`, staples and validates the app, checks Gatekeeper, then rebuilds the final ZIP and checksum before publishing.

If an older local installation was signed by a different team, pause capture and run `python3 scripts/build-install.py --configuration Release` once. This preserves local history and backs up the old app. macOS may require permissions again after the signing change. The in-app updater continues to reject cross-team updates.

## Public distribution verification

Publish from the default branch after required checks pass. Keep public distribution separate from the installed development app.

1. Confirm a clean checkout, current `origin/main`, no required unmerged work, and an unused version tag matching `JotVersion.current` in `Sources/JotCore/JotVersion.swift`, `Resources/Info.plist`, and `project.yml`.
2. Run `swift test` and `./scripts/build-install.py --configuration Release --build-only`. The script resolves the actual Xcode product, verifies the owner signing team and signatures, rejects DEBUG and feedback artifacts, and writes `build/release-proof.json`.
3. Confirm the product contains `ThirdPartyNotices.txt`, no private transcripts, audio recordings, credentials, or development reports. Review README screenshots for private content. Models download separately on first use.
4. Create a ZIP with `ditto -c -k --sequesterRsrc --keepParent` from the resolved app. Submit it using `xcrun notarytool submit` with an authorized keychain profile and wait for Accepted. Never put credentials into the repository or release logs.
5. Run `xcrun stapler staple` and `xcrun stapler validate` on the app, then `codesign --verify --deep --strict` and `spctl --assess --type execute --verbose=4`. All must pass. Recreate the ZIP after stapling and compute its SHA-256 checksum.
6. Create the version tag at the verified default-branch commit and a GitHub release with the final ZIP, checksum, requirements, privacy behavior, and release notes. Verify the uploaded download checksum. Do not publish an unnotarized candidate as the finished release.

## Public release status

GitHub releases v0.1.1 through v0.2.1 are marked prerelease because they were local testing builds, not notarized public artifacts. The first supported public release is waiting for a Developer ID Application certificate for owner team `N6GPP46885` and a matching `notarytool` keychain profile. The current Mac has Monroe's Apple Development certificate, which is valid for local development but cannot be notarized for distribution.
