# CLAUDE.md

Panes is a macOS 26 menu-bar window grid (a native arm64 rebuild of Divvy), written as a Swift 6.2
package with no dependencies. `README.md` covers features, the config format and the source layout;
`CONTRIBUTING.md` covers the rules for changes. Read them before larger work.

## Commands

Always pass `--scratch-path`: the checkout can sit in an iCloud-synced folder, and `codesign` rejects
build output there ("resource fork, Finder information, or similar detritus").

```sh
swift test  --scratch-path ~/Library/Caches/Panes/build   # unit tests (PanesCore only)
swift build --scratch-path ~/Library/Caches/Panes/build   # debug build
scripts/build-app.sh            # release Panes.app into ~/Library/Caches/Panes/dist/
scripts/build-app.sh --install  # also copies to ~/Applications, kills and relaunches Panes
```

Never create a `.build/` in the repo. `--install` replaces the running app, so ask before using it.

## Architecture

- `Sources/PanesCore/`: pure, `Sendable`, UI-free logic (grid geometry, `KeyCombo` parsing, `Config`,
  `DivvyImport`). Anything testable goes here, with tests in `Tests/PanesCoreTests/` (Swift Testing).
  It must not import AppKit or Carbon: the keyboard layout is injected as a `KeyLayout`.
- `Sources/Panes/`: the app, all `@MainActor`. `AppDelegate` owns the status item, wires hotkeys and
  moves windows; `Store` is the single source of truth and saves `config.json` (debounced 300 ms,
  flushed on quit and when Settings closes). Its `onChange` re-registers every hotkey.
- `System/HotkeyCenter` registers shortcuts with Carbon `RegisterEventHotKey` (no Accessibility needed,
  key press consumed). `System/WindowMover` moves the focused window of another app via the
  Accessibility API.

## Pitfalls

- **Two coordinate spaces.** AppKit is bottom-left origin, y up; Accessibility/Quartz is top-left of the
  primary screen, y down. `GridSelection.frame(in:)` works in Accessibility space; convert with
  `flipped(_:primaryScreenHeight:)`. Mixing them breaks multi-screen placement.
- **Shortcuts store key positions, not characters.** A combo is a virtual key code; character keys in
  `config.json` resolve against the active layout (`w` is key code 13 on QWERTY, 6 on AZERTY). Test
  layout-dependent code with an explicit `KeyLayout`, not `.usANSI` alone.
- **`WindowMover` order is deliberate**: size, position, size again, with `AXEnhancedUserInterface`
  turned off around it. Don't simplify it.
- **Config compatibility.** Existing `config.json` files must keep loading: new fields use
  `decodeIfPresent` with a default in the custom `init(from:)`.
- **Accessibility grants follow the signature.** Ad-hoc builds lose the grant on every rebuild; that
  is expected, not a bug (see "Signing" in the README).
- UI and window moving have no tests. Verify them in the real app and say so when you can't.

## Conventions

- SwiftUI first, AppKit only where SwiftUI falls short. Comments explain why, not what.
- Every user-visible change gets a line under `[Unreleased]` in `CHANGELOG.md`, and the README is
  updated when behaviour or the config format changes.
- Commit messages in the imperative ("Cancel grid drag on Escape"), with a body when the reason isn't
  obvious. Do not add `Co-Authored-By: Claude` or other AI attribution trailers to commits or PRs.
