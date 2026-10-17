# Jot in Vorssaint

Jot integrations should fit the tools people already use. Jot remains a standalone app; hosts use its reusable local control API and own only their presentation. The intended Vorssaint integration is a normal optional built-in feature, using its existing Features hub, settings, navigation, lifecycle and update path. It is not a new plugin loader or a separately branded Jot product.

## Prepared upstream contribution

[optional-jot-feature.patch](optional-jot-feature.patch) applies to upstream Vorssaint commit `5457c2d69a0dffb62a7c644252e28207b1188457`. It adds:

- An opt-in **Jot** feature in the Sound group, with normal install/uninstall behavior and saved choices.
- A searchable Jot settings/sidebar page, a feature-gated menu panel, and an Island Controls shortcut.
- Play/Pause, Start/End Meeting, Open Jot and Quit Jot; Jot remains the capture, history and insertion owner.
- Fn activity feedback using text-free control state, including Reduce Motion support. Disabling the feature stops its observer/timer and removes the presentation.

The contribution preserves Vorssaint's normal name, app identity, signing, fan behavior and updater. Jot is installed separately; enabling the integration never starts capture. See [the control-surface contract](../../CONTROL-SURFACES.md).

From a checkout at the upstream base, review and apply it with:

```sh
git apply --check /path/to/optional-jot-feature.patch
git apply /path/to/optional-jot-feature.patch
```

Validation on Monroe's Mac: affected native developer build, app selftest, 1,177 feature checks, 534 settings checks and 66,124 notch checks passed. The new feature checks cover opt-in behavior, normal feature installation/removal, settings/shortcut visibility, no permission ownership, and saved off choices. Test preferences are isolated and removed.

This is a prepared contribution. No upstream PR has been submitted or accepted, and the stock release does not contain it. Maintainer review, translation of the new English copy, physical Fn/Tab and meeting interaction, and Jot's separate public signing/notarization gate remain before calling it a generally released integration.

## Current personal installation

The existing Vorssaint+Jot app stays installed temporarily, preserving its configuration. The contribution candidate was built for validation and was not installed over it. Daily upkeep maintains that temporary installation and reports if upstream adopts Jot; it will not silently migrate to stock.

Jot's checked Release update restores its standalone menu bar when the temporary controller is absent and hides it again when the controller returns, unless “Always show menu bar icon” is on. Native checks exercised real controller exit/relaunch. The main window and private history remain in Jot; a controller is always optional.
