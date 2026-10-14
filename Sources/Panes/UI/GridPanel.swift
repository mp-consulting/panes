import AppKit
import PanesCore
import SwiftUI

/// A borderless panel that can take keyboard focus (for Escape) without activating Panes, so the
/// app whose window is being placed stays frontmost.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The Divvy-style grid that opens from the menu-bar icon or the grid hotkey.
@MainActor final class GridPanelController: NSObject, NSWindowDelegate {
    private let store: Store
    private let updater: Updater
    private let apply: (NSRunningApplication, GridSelection, NSScreen) -> Void
    private let openSettings: () -> Void
    private var panel: FloatingPanel?
    private var content: NSHostingController<GridPanelView>?
    private let resizePreview = ResizePreview()
    private var target: NSRunningApplication?
    /// The screens when the panel opened. It closes when they change, so these stay current.
    private var screens: [NSScreen] = []
    /// The screen the grid places the window on: the window's own at first, then the one picked.
    private var screenIndex = 0
    /// That screen, menu bar and Dock excluded, in Accessibility coordinates.
    private var targetArea: CGRect = .zero

    init(store: Store,
         updater: Updater,
         apply: @escaping (NSRunningApplication, GridSelection, NSScreen) -> Void,
         openSettings: @escaping () -> Void) {
        self.store = store
        self.updater = updater
        self.apply = apply
        self.openSettings = openSettings
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// - Parameters:
    ///   - target: the app whose focused window will move.
    /// The panel opens centred on the target window's screen, like Divvy's.
    func show(for target: NSRunningApplication?) {
        close()
        let screens = NSScreen.screens
        let windowFrame = WindowMover.focusedWindowFrame(of: target)
        guard let screen = windowFrame.flatMap(WindowMover.screen(for:)) ?? NSScreen.main ?? screens.first
        else { return NSSound.beep() }
        self.target = target
        self.screens = screens
        screenIndex = screens.firstIndex { $0.frame == screen.frame } ?? 0

        let controller = NSHostingController(rootView: makeView())
        let panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = controller
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        content = controller

        let size = layOut()
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        resizePreview.hide()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Points the grid at another screen: its shape, the preview, and where the window goes.
    private func selectScreen(_ index: Int) {
        guard let panel, screens.indices.contains(index), index != screenIndex else { return }
        screenIndex = index
        resizePreview.hide()
        let size = layOut()
        // Grown or shrunk from the top-right corner, so the screen picker stays under the pointer.
        let old = panel.frame
        panel.setFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// Rebuilds the content for the selected screen and returns the panel size it needs.
    private func layOut() -> NSSize {
        let screen = screens[screenIndex]
        targetArea = WindowMover.visibleArea(of: screen)
        guard let content else { return .zero }
        content.rootView = makeView()
        // Measure through the controller: an NSHostingView's fittingSize is zero until it has
        // been laid out in a window, which left the panel invisible at 0x0.
        return content.sizeThatFits(in: NSSize(width: 1000, height: 2000))
    }

    private func makeView() -> GridPanelView {
        let target = target
        let screen = screens[screenIndex].visibleFrame
        let aspect = screen.width / max(screen.height, 1)
        return GridPanelView(
            store: store, updater: updater, target: target, aspect: aspect,
            // Wide screens get a wider panel, so the grid keeps a usable height (~230pt).
            width: min(max(230 * aspect + 32, 380), 760),
            screens: screens.map { ScreenPicker.Screen(frame: WindowMover.frame(of: $0), name: $0.localizedName) },
            selectedScreen: screenIndex,
            selectScreen: { [weak self] index in self?.selectScreen(index) },
            previewScreen: { [weak self] index in self?.previewScreen(index) },
            apply: { [weak self] selection in
                guard let self else { return }
                let screen = screens[screenIndex]
                close()
                if let target { apply(target, selection, screen) }
            },
            preview: { [weak self] selection in self?.preview(selection) },
            cancel: { [weak self] in self?.close() },
            openSettings: { [weak self] in
                self?.close()
                self?.openSettings()
            }
        )
    }

    private func preview(_ selection: GridSelection?) {
        guard let selection, store.config.showResizePreview, targetArea.width > 0 else {
            return resizePreview.hide()
        }
        let frame = selection.frame(in: targetArea)
        resizePreview.show(flipped(frame, primaryScreenHeight: WindowMover.primaryScreenHeight))
    }

    /// Hovering a screen in the picker outlines that whole screen, to tell which one it is.
    private func previewScreen(_ index: Int?) {
        guard let index, screens.indices.contains(index), store.config.showResizePreview else {
            return resizePreview.hide()
        }
        resizePreview.show(screens[index].visibleFrame)
    }
}

struct GridPanelView: View {
    let store: Store
    let updater: Updater
    let target: NSRunningApplication?
    let aspect: CGFloat
    let width: CGFloat
    let screens: [ScreenPicker.Screen]
    let selectedScreen: Int
    let selectScreen: (Int) -> Void
    let previewScreen: (Int?) -> Void
    let apply: (GridSelection) -> Void
    let preview: (GridSelection?) -> Void
    let cancel: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !WindowMover.isTrusted {
                accessibilityWarning
            }

            GridSelector(columns: store.config.grid.columns, rows: store.config.grid.rows, onPreview: preview, onCancel: cancel, onCommit: apply)
                .frame(height: (width - 32) / max(aspect, 0.5))

            // Same rule as the hotkeys: an area outside its grid would place the window off screen.
            let presets = store.config.presets.filter { $0.enabled && $0.area.isValid }
            if !presets.isEmpty {
                GlassEffectContainer(spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        ForEach(presets) { preset in
                            PresetButton(preset: preset, shortcut: store.display(preset.key)) { apply(preset.area) }
                                .onHover { preview($0 ? preset.area : nil) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = target?.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            Text(target?.localizedName ?? "No window")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if screens.count > 1 {
                ScreenPicker(screens: screens, selected: selectedScreen, onSelect: selectScreen, onHover: previewScreen)
            }
            if let release = updater.availableRelease {
                Button("Update", systemImage: "arrow.down.circle.fill", action: openSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .help("Panes \(release.version.description) is available")
            }
            Button("Settings", systemImage: "gearshape", action: openSettings)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Settings…")
        }
    }

    private var accessibilityWarning: some View {
        Button {
            WindowMover.requestTrust()
            WindowMover.openAccessibilitySettings()
        } label: {
            Label("Allow Panes in Accessibility settings to move windows", systemImage: "hand.raised.fill")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .tint(.orange)
    }
}

/// The connected screens in their arrangement, as in System Settings → Displays. Clicking one points
/// the grid at that screen.
struct ScreenPicker: View {
    struct Screen {
        /// In Accessibility coordinates.
        let frame: CGRect
        let name: String
    }

    let screens: [Screen]
    let selected: Int
    let onSelect: (Int) -> Void
    let onHover: (Int?) -> Void

    private let height: CGFloat = 28

    var body: some View {
        let bounds = screens.reduce(CGRect.null) { $0.union($1.frame) }
        // Screens side by side get a wide picker, stacked ones a narrow one; either fits the header.
        let width = min(max(height * bounds.width / max(bounds.height, 1), 20), 120)
        let tiles = ScreenLayout.miniature(of: screens.map(\.frame), fitting: CGSize(width: width, height: height))
        ZStack(alignment: .topLeading) {
            ForEach(tiles.indices, id: \.self) { index in
                let tile = tiles[index].insetBy(dx: 1, dy: 1)
                let isSelected = index == selected
                Button { onSelect(index) } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.15)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(.primary.opacity(isSelected ? 0 : 0.3), lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: max(tile.width, 0), height: max(tile.height, 0))
                .position(x: tile.midX, y: tile.midY)
                .onHover { onHover($0 ? index : nil) }
                .help(screens[index].name)
                .accessibilityLabel("Place on \(screens[index].name)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(width: width, height: height)
    }
}

struct PresetButton: View {
    let preset: Config.Preset
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GridThumbnail(area: preset.area)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.callout.weight(.medium)).lineLimit(1)
                    if let shortcut {
                        Text(shortcut).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
    }
}
