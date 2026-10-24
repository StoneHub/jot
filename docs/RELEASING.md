# Releasing Jot

## Local releases

Official releases are cut on Monroe's Mac with `scripts/release.py`. They require a Developer ID Application certificate for owner team `N6GPP46885`, hardened runtime, and Apple notarization. Every official update uses that team so installed permissions and the updater's signature check remain stable.

```sh
python3 scripts/release.py patch --notes "What changed" --install
```

`patch`, `minor`, `major`, or an explicit `X.Y.Z` picks the new version. The script, one printed line per step:

1. Refuses unless it is on `main`, the tree is clean, `HEAD` equals `origin/main` after a fetch, `gh auth status` passes, and a signing identity is set. An official release also needs the Developer ID certificate and asks `notarytool history` whether the notary profile works, so missing credentials stop it before the tests and build.
2. Bumps `JotVersion.current`, `project.yml`, and `Resources/Info.plist`. `CFBundleShortVersionString` is the version; `CFBundleVersion` is the number of existing `v*` tags plus one, so it increases every release. Writes `docs/release-notes/<version>.md` from `--notes`. Without `--notes`, it uses the reviewed draft in `docs/release-notes/next.md`, drops the draft's title line, and renames the draft in the release commit. Draft user-facing notes there in PRs as changes land, so the release needs no notes typed at the terminal.
3. Runs `swift test`, then `build-install.py --configuration Release --build-only`, and reads `build/release-proof.json`. The build check requires every bundled helper (`jot`, `jot-lab`, `jot-vorssaint`) and `VorssaintIntegration.json`, and for Release checks that each helper is signed by the release team with the hardened runtime, which notarization requires.
4. Zips the product, submits it to Apple with `notarytool`, and waits for `Accepted` before continuing. Any other result prints Apple's issue log (`notarytool log`) and stops.
5. Staples and validates the notarization ticket, verifies the signature and requires Gatekeeper to report `source=Notarized Developer ID`, then recreates `build/Jot-<version>.zip` and its checksum from the stapled app.
6. Commits `Release <version>`, creates the annotated tag `v<version>` with the notes as its message, pushes `main --follow-tags`, and runs `gh release create` with the zip and checksum. The asset must be named `Jot-<version>.zip`; the updater asks for exactly that name.
7. With `--install`, verifies the final ZIP checksum, extracts it into a temporary directory, and runs `build-install.py --configuration Release --product <extracted Jot.app>` with the expected signing team, version, build number and original executable SHA-256. This installs the packaged product into `/Applications` without a second build or another signing-identity lookup.

For a requested release-and-install batch, use this one release command with `--install`. A separate source-build installation before it would rebuild an intermediate version; the packaged-product handoff already verifies and installs the final artifact.

## Notarization setup

Done once, on the Mac that cuts releases, by the Account Holder of team `N6GPP46885` (only that role can create Developer ID certificates).

1. **Developer ID Application certificate.** In Xcode, open **Settings → Accounts**, select the Apple ID and team `N6GPP46885`, choose **Manage Certificates…**, click **+** and pick **Developer ID Application**. The private key stays in this Mac's login keychain. Check it with `security find-identity -v -p codesigning | grep "Developer ID Application"`; the line ends in `(N6GPP46885)`.
2. **App-specific password.** At [account.apple.com](https://account.apple.com), open **Sign-In and Security → App-Specific Passwords**, add one named `jot-notary`, and copy it.
3. **Notary profile.** Run `xcrun notarytool store-credentials jot-notary --apple-id <Apple ID of the account holder> --team-id N6GPP46885` and paste the app-specific password when asked. The credentials live in the keychain, never in the repository.
4. **Proof without publishing.** `python3 scripts/release.py patch --dry-run --with-notarization` checks the certificate and profile, tests, builds, submits the candidate to Apple, staples it and checks Gatekeeper, then restores the tree. It tags and publishes nothing.

`release.py` uses the profile named `jot-notary`; set `JOT_NOTARY_PROFILE` only to use another name. The first notarized build carries a Developer ID signature instead of the Apple Development one, so macOS may ask again for Microphone, Accessibility and the other permissions once after that update.

## Local pre-releases

Until the Developer ID certificate and notarization credentials exist, `--local` publishes a release signed with the installed development identity:

```sh
python3 scripts/release.py patch --notes "What changed" --local --install
```

It runs the same steps without notarization and marks the GitHub release as a pre-release. The in-app updater accepts it: it strips the quarantine flag and requires the download's TeamIdentifier to match the running app, so the build installs on Macs that trust that development certificate and nowhere else.

Each release also rewrites `version` and `sha256` in the Homebrew cask, `Casks/jot.rb`, in the release commit; see [HOMEBREW.md](HOMEBREW.md).

`--dry-run` verifies the owner certificate and notary profile, tests and builds the app, creates an unstapled candidate ZIP, prints the remaining notarization and publication work, and restores the tree without submitting or publishing. Add `--with-notarization` to submit, staple and check Gatekeeper too, still without tagging or publishing.

The packaged-product installer requires all four `--expected-team`, `--expected-version`, `--expected-build` and `--expected-sha256` arguments, plus `--configuration Release`. The extracted Jot.app must be a real directory directly inside the extraction directory. Every bundle entry must resolve within that app; contained framework symlinks remain valid, while external, dangling and cyclic symlink targets are refused. The installer repeats these checks on the supplied path before reading metadata, then checks Jot's bundle identifier, executable, bundled CLI, signature, team, release entitlements and feedback exclusion before stopping any runtime. `--build-only` verifies a supplied product without installing it. The ordinary source-build command still builds and resolves its product through Xcode build settings.

Both install paths refuse active capture, inference, model transitions, pending storage, dictation recovery or speaker work. They confirm the installed runtime's executable path before stopping it, copy into an empty destination, and verify the copied product against the expected identity and executable hash. Failed copying or verification restores the previous bundle. Failed launch verification retains the backup and does not write a success proof; capture and history are never reset. A successful install records the executable hash, version, build, signing team and launched runtime in `build/install-proof.json`.

Synthetic regressions run with `python3 -m unittest discover -s scripts -p 'test_*install.py'`. They mock signing, builds, runtime control and publication, and use temporary fixture bundles. They do not establish live-install, notarization or Gatekeeper acceptance.

Local source builds use the developer's own installed signing identity. On Monroe's Mac they prefer his Apple Development identity. `JOT_SIGN_IDENTITY` and `JOT_SIGN_TEAM` select another installed identity. Build and install proof record the verified team.

Official releases are stricter: `release.py` accepts only a Developer ID Application certificate for `N6GPP46885` and a working notary profile, `jot-notary` unless `JOT_NOTARY_PROFILE` names another, stored with `xcrun notarytool store-credentials` (see [Notarization setup](#notarization-setup)). It submits the ZIP, waits for `Accepted`, staples and validates the app, checks Gatekeeper, then rebuilds the final ZIP and checksum before publishing.

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

Every GitHub release so far, v0.1.1 through v0.3.3, is marked prerelease because each was a local testing build, not a notarized public artifact. The GitHub release text is the notes without their heading, because the in-app updater shows its first line, followed by an Install section with requirements and the move-to-Applications step; a `--local` release adds the Gatekeeper **Open Anyway** step. `--dry-run` writes that text to `build/Jot-<version>-release.md` and prints the line the updater will show. The first supported public release is waiting for a Developer ID Application certificate for owner team `N6GPP46885` and a matching `notarytool` keychain profile. The current Mac has Monroe's Apple Development certificate, which is valid for local development but cannot be notarized for distribution.
