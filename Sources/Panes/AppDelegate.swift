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
        apply: { [weak self] app, selection, screen in self?.move(app, to: selection, on: screen) },
        openSettings: { [weak self] in self?.showSettings() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.topleft.filled", accessibilityDescription: "Panes")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        HotkeyCenter.shared.install()
        store.onChange = { [weak self] in self?.registerHotkeys() }
        registerHotkeys()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshKeyboardLayout() }
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
        var screen: NSScreen?
        if store.config.cycleScreens, let lastPlacement,
           let frame = WindowMover.focusedWindowFrame(of: app),
           lastPlacement.isRepeated(area: selection, processID: app.processIdentifier, frame: frame) {
            screen = WindowMover.screen(after: frame)
        }
        let frame = move(app, to: selection, on: screen)
        lastPlacement = frame.map { Placement(processID: app.processIdentifier, area: selection, frame: $0) }
    }

    /// Returns where the window ended up, or `nil` when it couldn't be moved.
    @discardableResult
    private func move(_ app: NSRunningApplication, to selection: GridSelection, on screen: NSScreen? = nil) -> CGRect? {
        do {
            return try WindowMover.move(windowOf: app, to: selection, on: screen)
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
            menu.addItem(withTitle: "Update to Panes \(release.version)…", action: #selector(showSettingsFromMenu), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Show Grid", action: #selector(showGridFromMenu), keyEquivalent: "").target = self
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

    // MARK: Settings window

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsView.size),
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
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store, updater: updater))
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

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        store.flush()
        NSApp.setActivationPolicy(.accessory)
    }
}
