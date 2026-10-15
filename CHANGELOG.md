# Changelog

All notable changes to Panes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release tags are `v<version>`.

## [Unreleased]

### Changed

- Turning the grid panel over is one continuous half-turn: the card no longer vanishes for a moment
  as it passes edge-on.

## [1.4.1] - 2026-10-15

### Fixed

- The grid panel's gear no longer wears a focus ring as the panel opens.

## [1.4.0] - 2026-10-15

### Changed

- Columns and rows are set with sliders instead of up/down arrows, in Settings → General and in the
  preset editor.
- The grid panel opens about four times faster: the settings on its back are only built once the
  pointer reaches the gear.
- Dragging across a large grid stays smooth: a 24×24 grid redraws in a quarter of the time.
- Turning the grid panel over no longer freezes on a sliver of the old face halfway through.
- Shortcuts for Preview's windows no longer search every running process on each press.

## [1.3.1] - 2026-10-15

### Fixed

- Windows of Preview, and of other apps macOS reports without a process ID, move again instead of
  beeping.

## [1.3.0] - 2026-10-14

### Added

- The grid panel shows your screens as icons, the main screen first, when more than one is connected.
  Click one to drag the grid, or pick a preset, for that screen; hovering it outlines the screen.
- The gear in the grid panel turns the panel over to the settings, at full size, and back.
- Monitor cycling, as in Divvy: with **Repeat a shortcut for the next screen** on (Settings → General),
  pressing a preset's shortcut again moves the window to the same area of the next screen.

### Changed

- Without a config file or Divvy settings to import, Panes now starts with a 6×6 grid on
  ⌃⌥⌘Space, six presets (Center, Left, Right, Up, Down and Wide, on ⌃⌥⌘C, ←, →, ↑, ↓ and W) and
  monitor cycling on, instead of three halves-and-full-screen presets.

### Fixed

- The grid panel closes when a display is connected, removed or rearranged, instead of placing the
  window with the old screen's size.
- "Another app already uses this shortcut" clears as soon as the app holding the shortcut quits,
  instead of staying until the next settings change.

## [1.2.0] - 2026-10-14

### Added

- Update checks: release builds ask GitHub once a day for a newer release, show it in the grid panel,
  the menu and Settings, and install it in one click after checking that the download is notarized and
  signed by Panes's developer. The check can be turned off in Settings → General.

## [1.1.0] - 2026-10-14

### Changed

- The bundle identifier is now `com.mpconsulting.Panes`. macOS treats this as a new app: allow it
  once more in Privacy & Security → Accessibility, turn **Open Panes at login** back on if you used
  it, and remove the old Panes entries from both lists.
- A shortcut whose only modifier is shift, such as `shift+a`, is refused (except on F1–F15): as a
  global hotkey it took over typing that capital, or selecting text, in every app. Existing ones are
  flagged in Settings.

### Fixed

- A `config.json` that can't be read, such as one with a typo from a hand edit, is kept as
  `config-unreadable-<date>.json` instead of being overwritten, and Settings opens to say so.
- Out-of-range grid sizes in a hand-edited `config.json` are brought into range when it's read,
  instead of placing windows at invalid coordinates or crashing the preset editor.
- The grid panel no longer shows a button for a preset whose area lies outside its grid; Settings
  already flagged it and its shortcut was already off.
- Shortcuts on the keypad's + key can be recorded and saved; they used to be rejected when read back.
- No crash when a hotkey arrives with no display connected; Panes beeps instead.

## [1.0.0] - 2026-10-14

### Added

- Drag-to-place grid, opened from the menu-bar icon or the grid hotkey, centred on the screen of the
  front window. Escape closes it, and during a drag cancels the resize.
- Resize preview: a glass outline on the real screen shows where the window will land while you drag
  or hover a preset.
- Presets: grid areas with optional global shortcuts, also shown as buttons in the grid panel.
- Settings window to create, duplicate, reorder and delete presets, record shortcuts and set the grid
  size, with shortcut conflicts flagged.
- Divvy import of the grid size and shortcuts, including subdivided grids, on first launch and from
  Settings.
- Keyboard-layout-aware shortcuts.
- Multiple-screen support: windows are placed on the screen they're mostly on.
- Open at login option.
- Configuration saved as JSON in `~/Library/Application Support/Panes/config.json`.
- Release workflow that builds, signs, notarizes and attaches a DMG to each published GitHub release.

[Unreleased]: https://github.com/mp-consulting/panes/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/mp-consulting/panes/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/mp-consulting/panes/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/mp-consulting/panes/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/mp-consulting/panes/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/mp-consulting/panes/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/mp-consulting/panes/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mp-consulting/panes/releases/tag/v1.0.0
