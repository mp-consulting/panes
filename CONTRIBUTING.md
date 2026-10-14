# Contributing to Panes

Thanks for helping. Bug reports, fixes and small features are welcome. For anything larger, such as
a new setting or a Divvy option that isn't carried over yet, open an issue first so we can agree on
the approach before you write it.

## Reporting a bug

Open an issue with:

- your macOS version and Mac model,
- the Panes version (the release you installed, or the commit you built),
- the app whose window misbehaved, and what you expected instead,
- your `~/Library/Application Support/Panes/config.json` if the bug involves presets or shortcuts.

## Setting up

You need an Apple Silicon Mac on macOS 26 or later and Xcode with Swift 6.2 or later.

```sh
scripts/create-signing-identity.sh                        # once per Mac, keeps Accessibility access across rebuilds
swift test  --scratch-path ~/Library/Caches/Panes/build   # unit tests
scripts/build-app.sh --install                            # build, install to ~/Applications and relaunch
```

Keep build output out of the repo (the scripts use `~/Library/Caches/Panes`): if the checkout sits in
an iCloud-synced folder, `codesign` rejects the Finder metadata iCloud adds. The README's
"Development" section maps out the source folders.

## Making a change

- **Put logic in `PanesCore` and test it.** Grid geometry, shortcut parsing, the config format and the
  Divvy importer live there because they can be tested without a UI. Add or update tests in
  `Tests/PanesCoreTests/` for any change to it.
- **Try UI and window-moving changes in the real app.** They aren't unit-tested: run
  `scripts/build-app.sh --install` and check the change by hand, on more than one screen if it touches
  placement.
- **Match the surrounding code**: its naming, its comment density, and its preference for SwiftUI with
  AppKit only where SwiftUI falls short. Comments explain *why*, not what.
- **No dependencies.** The package has none, and adding one needs a strong reason.
- **Keep the config file compatible.** Existing `config.json` files must keep loading. New keys need
  defaults so they can be left out.
- **Update the docs.** User-visible behaviour belongs in `README.md`, and every user-visible change
  gets a line under `[Unreleased]` in `CHANGELOG.md`.

## Pull requests

- One change per pull request, with a description of what it changes and how you tested it.
- `swift test` must pass; CI runs it, with a release build, on every pull request. Include a
  screenshot or short recording for UI changes.
- Write commit messages in the imperative ("Cancel grid drag on Escape"), with a body when the reason
  isn't obvious.

## Releasing (maintainers)

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading.
2. Commit, then publish a GitHub release tagged `vx.y.z`.
3. The release workflow builds, signs and notarizes the DMG and attaches it to the release. See the
   README's "Releases" section for the secrets it needs.

## Licence

Panes is released under the [MIT License](LICENSE). By contributing, you agree that your contribution
is released under the same licence.

Panes is independent of Mizage. Don't contribute Divvy's code, artwork or other assets.
