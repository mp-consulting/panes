import AppKit
import Carbon
import PanesCore
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private lazy var updater = Updater(store: store)
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private lazy var gridPanel = GridPanelController(
        store: store,
        updater: updater,
        apply: { [weak self] app, selection, screen in self?.move(app, to: selection, on: screen) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.topleft.filled", accessibilityDescription: "Panes")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Right-click is the only way to the menu, and so to Quit.
            button.toolTip = "Panes: click for the grid, right-click for the menu"
        }
        // Lit while the grid is open, as a menu-bar extra is while its menu is.
        gridPanel.visibilityChanged = { [weak self] visible in self?.statusItem.button?.highlight(visible) }

        HotkeyCenter.shared.install()
        store.onChange = { [weak self] in self?.registerHotkeys() }
        registerHotkeys()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshKeyboardLayout() }
        }
        // A shortcut another app held is free once that app quits: take it then, instead of
        // flagging it until the next settings change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.refusedHotkeys.isEmpty else { return }
                self.registerHotkeys()
            }
        }

        if store.isFirstRun || store.loadError != nil {
            showSettings()
        }
        if !WindowMover.isTrusted {
            WindowMover.requestTrust()
        }
        updater.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    // MARK: Hotkeys

    /// One registration: the preset that owns it (`nil` for the grid hotkey) and what it does.
    private struct Hotkey: Equatable {
        let owner: UUID?
        let combo: KeyCombo
        /// The area a preset moves the window to; `nil` opens the grid.
        let area: GridSelection?
    }

    /// What was last registered. Most edits (a preset's name, the grid size) leave the hotkeys as
    /// they are, and re-registering on each keystroke would churn every Carbon registration.
    private var registeredHotkeys: [Hotkey]?

    private func registerHotkeys() {
        guard !store.isRecordingShortcut else {
            HotkeyCenter.shared.unregisterAll()
            registeredHotkeys = nil
            return
        }
        var hotkeys: [Hotkey] = []
        if let key = store.config.gridHotkey, let combo = try? KeyCombo(parsing: key, layout: store.layout) {
            hotkeys.append(Hotkey(owner: nil, combo: combo, area: nil))
        }
        var taken = Set(hotkeys.map(\.combo))
        for preset in store.config.presets where preset.enabled && preset.area.isValid {
            guard let combo = try? KeyCombo(parsing: preset.key, layout: store.layout), !taken.contains(combo) else { continue }
            taken.insert(combo)
            hotkeys.append(Hotkey(owner: preset.id, combo: combo, area: preset.area))
        }
        // Refused combos are retried on every change, in case the app holding them has quit.
        guard hotkeys != registeredHotkeys || !store.refusedHotkeys.isEmpty else { return }
        registeredHotkeys = hotkeys

        let bindings = hotkeys.map { hotkey -> (combo: KeyCombo, action: () -> Void) in
            if let area = hotkey.area {
                (hotkey.combo, { [weak self] in self?.moveFrontmost(to: area) })
            } else {
                (hotkey.combo, { [weak self] in self?.showGrid() })
            }
        }
        let refused = Set(HotkeyCenter.shared.replace(with: bindings))
        let refusedOwners = Set(hotkeys.filter { refused.contains($0.combo) }.map(\.owner))
        if store.refusedHotkeys != refusedOwners { store.refusedHotkeys = refusedOwners }
    }

    // MARK: Actions

    /// Where the last preset shortcut put a window, for `cycleScreens`.
    private var lastPlacement: Placement?

    private func moveFrontmost(to selection: GridSelection) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return NSSound.beep() }
        lastPlacement = moving { () throws(WindowMover.Failure) in
            let window = try WindowMover.focusedWindow(of: app)
            var screen: NSScreen?
            if store.config.cycleScreens, let lastPlacement,
               lastPlacement.isRepeated(area: selection, processID: window.processID, frame: window.frame) {
                screen = WindowMover.screen(after: window.frame)
            }
            let frame = try WindowMover.move(window, to: selection, on: screen)
            return Placement(processID: window.processID, area: selection, frame: frame)
        }
    }

    private func move(_ app: NSRunningApplication, to selection: GridSelection, on screen: NSScreen) {
        moving { () throws(WindowMover.Failure) in try WindowMover.move(WindowMover.focusedWindow(of: app), to: selection, on: screen) }
    }

    /// Runs a window move and returns its result, or `nil` after asking for Accessibility access
    /// or beeping when the window couldn't be moved.
    @discardableResult
    private func moving<T>(_ body: () throws(WindowMover.Failure) -> T) -> T? {
        do {
            return try body()
        } catch .notTrusted {
            WindowMover.requestTrust()
            showSettings()
        } catch {
            NSSound.beep()
        }
        return nil
    }

    private func showGrid() {
        if gridPanel.isVisible { return gridPanel.close() }
        gridPanel.show(for: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            showGrid()
        }
    }

    private func showMenu() {
        gridPanel.close()
        let menu = NSMenu()
        if let release = updater.availableRelease {
            menu.addItem(withTitle: "Update to Panes \(release.version)…", action: #selector(showUpdatesFromMenu), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let showGrid = menu.addItem(withTitle: "Show Grid", action: #selector(showGridFromMenu), keyEquivalent: "")
        showGrid.target = self
        // Shown, as menus teach shortcuts; it works anywhere, so it isn't only a menu equivalent.
        if let key = store.config.gridHotkey, let combo = try? KeyCombo(parsing: key, layout: store.layout),
           let equivalent = Self.keyEquivalent(for: combo, layout: store.layout) {
            showGrid.keyEquivalent = equivalent
            showGrid.keyEquivalentModifierMask = Self.modifierMask(for: combo.modifiers)
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Panes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showGridFromMenu() {
        showGrid()
    }

    @objc private func showSettingsFromMenu() {
        showSettings()
    }

    @objc private func showUpdatesFromMenu() {
        store.revealUpdates = true
        showSettings()
    }

    /// The menu-item equivalent of a combo's key: its character, or the function-key character for
    /// the named keys menus can draw. `nil` for keys a menu can't show.
    private static func keyEquivalent(for combo: KeyCombo, layout: KeyLayout) -> String? {
        let named: [UInt32: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                    125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
                                    116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey,
                                    115: NSHomeFunctionKey, 119: NSEndFunctionKey]
        if let function = named[combo.keyCode], let scalar = Unicode.Scalar(function) { return String(Character(scalar)) }
        switch combo.keyCode {
        case 49: return " "
        case 36: return "\r"
        case 48: return "\t"
        default:
            guard let character = layout.characterForKeyCode[combo.keyCode], character.count == 1 else { return nil }
            return character.lowercased()
        }
    }

    private static func modifierMask(for modifiers: KeyCombo.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }

    // MARK: Settings window

    func showSettings() {
        if settingsWindow == nil {
            let size = SettingsView.size(on: NSScreen.main)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                // Fixed size: not resizable, so no zoom or full screen either.
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Panes"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // An empty unified toolbar makes the title bar taller, which drops the traffic lights
            // inside the floating sidebar instead of onto its top edge.
            window.toolbar = NSToolbar(identifier: "PanesSettings")
            window.toolbarStyle = .unified
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store, updater: updater, height: size.height))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.collectionBehavior = [.fullScreenNone]
            window.center()
            settingsWindow = window
        }
        // A Dock icon and ⌘-Tab entry while settings are open; menu-bar only otherwise.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The menu bar while Settings is open. Without one, ⌘Z, ⌘C, ⌘V and ⌘W had nothing to go
    /// through: a preset deleted by mistake couldn't be undone, nor a name pasted in.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu("Panes", [
            item("About Panes", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(showSettingsFromMenu), ",", target: self),
            .separator(),
            item("Hide Panes", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Panes", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            redo,
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        store.flush()
        NSApp.setActivationPolicy(.accessory)
    }
}
