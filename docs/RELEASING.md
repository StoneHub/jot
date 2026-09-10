# Public release checklist

Publish from the default branch after required checks pass. Keep public distribution separate from the installed development app.

1. Confirm a clean checkout, current `origin/main`, no required unmerged work, and an unused version tag matching `Resources/Info.plist` and `project.yml`.
2. Run `swift test` and `./scripts/build-install.py --configuration Release --build-only`. The script resolves the actual Xcode product, verifies Developer ID signatures, rejects DEBUG and feedback artifacts, and writes `build/release-proof.json`.
3. Confirm the product contains `ThirdPartyNotices.txt`, no private transcripts, audio recordings, credentials, or development reports. Review README screenshots for private content. Models download separately on first use.
4. Create a ZIP with `ditto -c -k --sequesterRsrc --keepParent` from the resolved app. Submit it using `xcrun notarytool submit` with an authorized keychain profile and wait for Accepted. Never put credentials into the repository or release logs.
5. Run `xcrun stapler staple` and `xcrun stapler validate` on the app, then `codesign --verify --deep --strict` and `spctl --assess --type execute --verbose=4`. All must pass. Recreate the ZIP after stapling and compute its SHA-256 checksum.
6. Create the version tag at the verified default-branch commit and a GitHub release with the final ZIP, checksum, requirements, privacy behavior, and release notes. Verify the uploaded download checksum. Do not publish an unnotarized candidate as the finished release.

## First release status

The initial version is 0.1.0 (build 1). Developer ID signing is available. On September 9, 2026, Gatekeeper rejected the candidate as `Unnotarized Developer ID`; no notarization profile was found in the configured user keychains or credential environment. An authorized notarization credential for the signing team is required before publishing. No version tag or public binary release was created at that checkpoint.
