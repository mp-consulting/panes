<p align="center">
  <img src="docs/icon.png" width="128" alt="Panes icon">
</p>

<h1 align="center">Panes</h1>

<p align="center">A native Apple Silicon window grid for macOS, after Divvy.<br>
Drag across a grid to place the front window, or press a shortcut.</p>

---

[Divvy](https://mizage.com/divvy/) has not been updated since 2017 and ships Intel code only, so on an
Apple Silicon Mac it runs through Rosetta, which Apple is phasing out. Panes rebuilds Divvy's
behaviour as a native arm64 app with a Liquid Glass interface. On first launch it imports your Divvy
presets.

![The grid panel](docs/screenshots/grid-panel.png)

## Features

- **Drag-to-place grid.** Click the menu-bar icon or press the grid hotkey: a grid opens centred on the
  screen of the front window. Drag across the cells you want; on release the window fills that zone.
- **Resize preview.** While you drag, or hover a preset button, a glass outline on the real screen
  shows where the window will land.
- **Presets with global shortcuts.** Each preset is a grid area. Give it a shortcut (⌃⌥⌘← and so on)
  or leave it as a button in the grid panel.
- **Settings window** to create, duplicate, reorder and delete presets, record shortcuts, and set the
  grid size. Shortcut conflicts are flagged next to the preset.
- **Divvy import.** Your Divvy grid size and shortcuts, including subdivided grids, are converted on
  first launch and can be re-imported from Settings.
- **Keyboard-layout aware.** Shortcuts follow the active layout, so a Divvy shortcut stored as the
  QWERTY "Z" key shows as ⌃⌥⌘W on AZERTY, which is the key it really is.
- **Multiple screens.** Windows are placed on the screen they're mostly on, inside the menu bar and Dock.
- Menu-bar only, with no Dock icon except while Settings is open. Optionally opens at login.

| General | Preset editor |
| --- | --- |
| ![General settings](docs/screenshots/settings-general.png) | ![Preset editor](docs/screenshots/settings-preset.png) |

## Requirements

- An Apple Silicon Mac running **macOS 26** or later (Liquid Glass needs it).
- **Xcode** with Swift 6.2 or later, to build.

## Install

```sh
scripts/create-signing-identity.sh   # once per Mac, see "Signing" below
scripts/build-app.sh --install       # builds, copies to ~/Applications, launches
```

`build-app.sh` alone builds `Panes.app` into `~/Library/Caches/Panes/dist/` without installing it.

Then:

1. **Quit Divvy** (and any other window manager using the same shortcuts). Panes flags a shortcut that
   another app already holds.
2. **Allow Accessibility access.** macOS asks on first launch, or go to System Settings → Privacy &
   Security → Accessibility and turn Panes on. Panes needs it to move other apps' windows.
3. Optionally turn on **Open Panes at login** in Settings → General.

### Signing

Accessibility access is tied to the app's code signature. With an ad-hoc signature (no certificate)
every rebuild counts as a new app, and macOS asks for access again even though System Settings still
shows Panes as allowed. `scripts/create-signing-identity.sh` creates a self-signed certificate,
**Panes Local Signing**, in your login keychain. `build-app.sh` uses it automatically, so one grant
survives every rebuild. To sign with another identity, set `SIGN_IDENTITY`.

If you switch from ad-hoc to the certificate, remove the old Panes entries from the Accessibility
list once and allow the new one.

## Using it

| Action | How |
| --- | --- |
| Open the grid | Click the menu-bar icon, or press the grid hotkey (set in Settings → General) |
| Place the window | Drag across the grid and release, or click a preset button |
| Apply a preset | Press its shortcut, with the window to place in front |
| Cancel a drag | Escape before releasing the mouse: the window stays put and the grid closes |
| Close the grid | Escape, the hotkey again, or click elsewhere |
| Settings, Quit | Right-click (or Control-click) the menu-bar icon, or the gear in the grid |

In the **preset editor**, drag on the grid to set the area. Columns and rows can change per preset,
and the selected area is rescaled to stay the same part of the screen. Click the shortcut button and
press a key combination to record it. Escape cancels, and × clears it. A shortcut needs at least one
modifier.

## Configuration file

Settings are saved as JSON in `~/Library/Application Support/Panes/config.json`. Settings → General has
a **Show in Finder** button. The app reads the file at launch and rewrites it on every change, so quit
Panes before editing it by hand.

```json
{
  "grid": { "columns": 7, "rows": 6 },
  "gridHotkey": "ctrl+opt+cmd+space",
  "showResizePreview": true,
  "presets": [
    {
      "name": "Left",
      "key": "ctrl+opt+cmd+left",
      "enabled": true,
      "area": { "columns": 7, "rows": 6, "start": { "column": 0, "row": 0 }, "end": { "column": 1, "row": 5 } }
    }
  ]
}
```

- `area` is a cell range on its own `columns` × `rows` grid. Row 0 is the top row, and both ends are
  included.
- `key` is modifiers plus a key, joined with `+`: modifiers `ctrl`, `opt`, `shift`, `cmd`; keys are a
  character on the active layout (`w`, `é`), or `left`, `right`, `up`, `down`, `space`, `return`,
  `tab`, `escape`, `delete`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f15`, `keypad0`–`keypad9`. An
  empty `key` makes a button-only preset.
- `id` and `enabled` can be left out; Panes fills them in.

## Divvy settings that are not carried over

Divvy's resize preview is reproduced. These other Divvy options are not:

- **Margins** between windows and around the screen edges.
- **Animations** when windows move.
- **Monitor cycling**: pressing a shortcut again to send the window to the next screen.
- Divvy's hidden `enableAcceleration` preference needs no counterpart. Despite its name, it only
  records that Divvy has been launched before, for its licence prompt.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| macOS asks for Accessibility although Panes is allowed | The build is signed ad-hoc. Run `scripts/create-signing-identity.sh`, rebuild, re-allow once. |
| A shortcut shows "Another app already uses this shortcut" | Another app holds the key combination, often Divvy. Quit it or pick another shortcut. |
| A shortcut does nothing | The front app has no focused window (the Finder desktop, for example), or Accessibility is off. Panes beeps. |
| `codesign` fails with "resource fork, Finder information, or similar detritus" | The build output is inside an iCloud-synced folder. `build-app.sh` builds in `~/Library/Caches/Panes`, so use the script, or pass `--scratch-path` to `swift build`. |

## Development

```sh
swift test  --scratch-path ~/Library/Caches/Panes/build   # unit tests
swift build --scratch-path ~/Library/Caches/Panes/build   # debug build
```

The project is a Swift package with no dependencies:

| Path | What it holds |
| --- | --- |
| `Sources/PanesCore/` | Pure logic: grid geometry, shortcut parsing, the config format, the Divvy importer. Fully unit-tested. |
| `Sources/Panes/System/` | macOS plumbing: Carbon global hotkeys, the Accessibility window mover, keyboard-layout lookup. |
| `Sources/Panes/UI/` | SwiftUI and AppKit: the grid panel, the resize preview, the settings window, the shortcut recorder. |
| `Sources/Panes/AppDelegate.swift`, `Store.swift` | The menu-bar item, hotkey wiring, and the config store that saves to disk. |
| `Tests/PanesCoreTests/` | Tests for `PanesCore`, including an import of a Divvy-shaped keyed archive. |
| `scripts/` | `build-app.sh` (bundle, sign, install), `make-dmg.sh` (disk image), `make-icon.swift` (renders the icon), `create-signing-identity.sh`. |

Divvy's shortcuts live in its preferences as an `NSKeyedArchiver` blob of `Shortcut` objects.
`DivvyImport` walks that archive as a plain property list, so no Divvy class is needed.

## Releases

Publishing a GitHub release runs [`.github/workflows/release.yml`](.github/workflows/release.yml):
it tests, builds with the version from the tag (`v1.2.0` → `1.2.0`), signs with a Developer ID
certificate, packs `Panes-<version>.dmg` with `scripts/make-dmg.sh`, notarizes it and attaches it
to the release. Before tagging, move the `[Unreleased]` entries in [CHANGELOG.md](CHANGELOG.md) under
the new version. The workflow needs these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE` | Your **Developer ID Application** certificate and key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you gave the `.p12` export |
| `APPLE_API_KEY` | The contents of an App Store Connect API key (`AuthKey_<id>.p8`), for notarization: `gh secret set APPLE_API_KEY < AuthKey_<id>.p8` |
| `APPLE_API_KEY_ID` | That key's ID (the `<id>` in the file name) |
| `APPLE_API_ISSUER` | The issuer ID shown above the key list (App Store Connect → Users and Access → Integrations) |

Without `APPLE_API_KEY` the DMG is signed but not notarized, and Gatekeeper blocks it on other Macs.
A release signed with Developer ID is a different signature from a local build, so macOS asks for
Accessibility access once more after switching.

To make a DMG locally: `scripts/build-app.sh && scripts/make-dmg.sh`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Mickael Palma

---

Panes is an independent project. It is not affiliated with Mizage, and Divvy is their product.
