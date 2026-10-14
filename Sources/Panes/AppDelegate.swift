import AppKit
import Carbon
import PanesCore
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private lazy var gridPanel = GridPanelController(
        store: store,
        apply: { [weak self] app, selection in self?.move(app, to: selection) },
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

        if store.isFirstRun {
            showSettings()
        }
        if !WindowMover.isTrusted {
            WindowMover.requestTrust()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        guard !store.isRecordingShortcut else {
            HotkeyCenter.shared.unregisterAll()
            return
        }
        var bindings: [(combo: KeyCombo, action: () -> Void)] = []
        var owners: [UUID?] = []

        if let key = store.config.gridHotkey, let combo = try? KeyCombo(parsing: key, layout: store.layout) {
            bindings.append((combo, { [weak self] in self?.showGrid() }))
            owners.append(nil)
        }
        var taken = Set(bindings.map(\.combo))
        for preset in store.config.presets where preset.enabled && preset.area.isValid {
            guard let combo = try? KeyCombo(parsing: preset.key, layout: store.layout), !taken.contains(combo) else { continue }
            taken.insert(combo)
            let area = preset.area
            bindings.append((combo, { [weak self] in self?.moveFrontmost(to: area) }))
            owners.append(preset.id)
        }

        let refused = Set(HotkeyCenter.shared.replace(with: bindings))
        let refusedOwners = Set(zip(bindings, owners).filter { refused.contains($0.0.combo) }.map(\.1))
        if store.refusedHotkeys != refusedOwners { store.refusedHotkeys = refusedOwners }
    }

    // MARK: Actions

    private func moveFrontmost(to selection: GridSelection) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return NSSound.beep() }
        move(app, to: selection)
    }

    private func move(_ app: NSRunningApplication, to selection: GridSelection) {
        do {
            try WindowMover.move(windowOf: app, to: selection)
        } catch .notTrusted {
            WindowMover.requestTrust()
            showSettings()
        } catch {
            NSSound.beep()
        }
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
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
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
