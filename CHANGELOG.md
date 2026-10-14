# Changelog

All notable changes to Panes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release tags are `v<version>`.

## [Unreleased]

### Fixed

- A `config.json` that can't be read, such as one with a typo from a hand edit, is kept as
  `config-unreadable-<date>.json` instead of being overwritten, and Settings opens to say so.
- Out-of-range grid sizes in a hand-edited `config.json` are brought into range when it's read,
  instead of placing windows at invalid coordinates or crashing the preset editor.
- The grid panel no longer shows a button for a preset whose area lies outside its grid; Settings
  already flagged it and its shortcut was already off.
- Shortcuts on the keypad's + key can be recorded and saved; they used to be rejected when read back.

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

[Unreleased]: https://github.com/mp-consulting/panes/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/mp-consulting/panes/releases/tag/v1.0.0
