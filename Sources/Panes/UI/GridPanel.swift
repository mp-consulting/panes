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
    private let apply: (NSRunningApplication, GridSelection) -> Void
    private let openSettings: () -> Void
    private var panel: FloatingPanel?
    private let resizePreview = ResizePreview()
    /// The target window's screen, menu bar and Dock excluded, in Accessibility coordinates.
    private var targetArea: CGRect = .zero

    init(store: Store,
         apply: @escaping (NSRunningApplication, GridSelection) -> Void,
         openSettings: @escaping () -> Void) {
        self.store = store
        self.apply = apply
        self.openSettings = openSettings
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// - Parameters:
    ///   - target: the app whose focused window will move.
    /// The panel opens centred on the target window's screen, like Divvy's.
    func show(for target: NSRunningApplication?) {
        close()
        let windowFrame = WindowMover.focusedWindowFrame(of: target)
        let screen = windowFrame.map(WindowMover.screen(for:)) ?? NSScreen.main ?? NSScreen.screens[0]
        targetArea = flipped(screen.visibleFrame, primaryScreenHeight: WindowMover.primaryScreenHeight)
        let aspect = screen.visibleFrame.width / max(screen.visibleFrame.height, 1)

        let view = GridPanelView(
            store: store, target: target, aspect: aspect,
            // Wide screens get a wider panel, so the grid keeps a usable height (~230pt).
            width: min(max(230 * aspect + 32, 380), 760),
            apply: { [weak self] selection in
                self?.close()
                if let target { self?.apply(target, selection) }
            },
            preview: { [weak self] selection in self?.preview(selection) },
            cancel: { [weak self] in self?.close() },
            openSettings: { [weak self] in
                self?.close()
                self?.openSettings()
            }
        )
        // Measure through the controller: an NSHostingView's fittingSize is zero until it has
        // been laid out in a window, which left the panel invisible at 0x0.
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(in: NSSize(width: 1000, height: 2000))

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = controller
        panel.setContentSize(size)
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
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        resizePreview.hide()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func preview(_ selection: GridSelection?) {
        guard let selection, store.config.showResizePreview, targetArea.width > 0 else {
            return resizePreview.hide()
        }
        let frame = selection.frame(in: targetArea)
        resizePreview.show(flipped(frame, primaryScreenHeight: WindowMover.primaryScreenHeight))
    }
}

struct GridPanelView: View {
    let store: Store
    let target: NSRunningApplication?
    let aspect: CGFloat
    let width: CGFloat
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

            let presets = store.config.presets.filter(\.enabled)
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
