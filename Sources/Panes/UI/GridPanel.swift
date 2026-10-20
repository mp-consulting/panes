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
    /// Whether the panel has turned over to the settings.
    private var showsSettings = false
    /// Whether the back of the card, the settings, has been built. Not until the first turn: it
    /// cost as much as the grid several times over, on every open, for a face rarely shown.
    private var hasSettingsFace = false
    /// The card's turn and its place in the panel, set together with the panel's frame.
    private var card = CardState()
    /// Where the panel goes once a turn ends: the new face's frame.
    private var frameAfterTurn: NSRect?

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
        let windowFrame = target.flatMap { try? WindowMover.focusedWindow(of: $0).frame }
        guard let screen = windowFrame.flatMap(WindowMover.screen(for:)) ?? NSScreen.main ?? screens.first
        else { return NSSound.beep() }
        self.target = target
        self.screens = screens
        showsSettings = false
        hasSettingsFace = false
        card = CardState()
        frameAfterTurn = nil
        screenIndex = screens.firstIndex { $0.frame == screen.frame } ?? 0

        let controller = NSHostingController(rootView: makeView())
        // The panel's size is set here alone: during a turn it holds both faces, and the controller
        // would otherwise shrink it to the face showing.
        controller.sizingOptions = []
        content = controller
        let size = layOut()
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = controller
        panel.setContentSize(size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow (`CardShadow`): the window's, traced from translucent glass,
        // came out as a hard grey ring offset under the card.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        // Nothing focused to start with: AppKit gives focus to the first control that takes it,
        // and with the settings not yet built on the back, that is the gear, ringed from the start.
        // Escape still reaches the panel through `cancelOperation`.
        panel.makeFirstResponder(nil)
        self.panel = panel
    }

    func close() {
        resizePreview.hide()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // A sheet from the settings (the Divvy import dialog) takes key without leaving the panel;
        // which window has it is only known once the change is through.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel, !panel.isKeyWindow, NSApp.keyWindow?.sheetParent !== panel else { return }
            close()
        }
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

    /// Before a turn: grows the panel to hold both the card where it is and the new face where it
    /// will land (about the same centre, kept on screen), without moving the card, and returns the
    /// card's offset at the end of the turn. Done while nothing moves, so the turn itself never
    /// resizes or lays out the panel.
    private func beginTurn() -> CGSize {
        guard let panel else { return .zero }
        showsSettings.toggle()
        // The grid is measured again on the way back: a preset added on the back adds a row of buttons.
        let size = showsSettings ? GridPanelView.settingsFaceSize : layOut()
        let old = panel.frame
        var new = NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            new.origin.x = min(max(new.minX, visible.minX), visible.maxX - new.width)
            new.origin.y = min(max(new.minY, visible.minY), visible.maxY - new.height)
        }
        let union = old.union(new)
        frameAfterTurn = new
        // SwiftUI's y axis points down, AppKit's up.
        card.offset = CGSize(width: old.midX - union.midX, height: union.midY - old.midY)
        if showsSettings { content?.rootView = makeView() }
        panel.setFrame(union, display: true)
        return CGSize(width: new.midX - union.midX, height: union.midY - new.midY)
    }

    /// After a turn: shrinks the panel to the face now showing, which stays where it is.
    private func endTurn() {
        guard let panel, let frame = frameAfterTurn else { return }
        frameAfterTurn = nil
        card.offset = .zero
        panel.setFrame(frame, display: true)
    }

    /// Adds the settings to the back of the card, still hidden: when the pointer reaches the gear,
    /// or when a flip finds the back missing.
    private func buildSettingsFace() {
        guard !hasSettingsFace else { return }
        hasSettingsFace = true
        content?.rootView = makeView()
        // Laid out now, while hidden: left to the next pass, it landed in the turn's first frames
        // and stalled the card mid-turn.
        content?.view.layoutSubtreeIfNeeded()
    }

    /// Rebuilds the content for the selected screen and returns the panel size it needs.
    private func layOut() -> NSSize {
        let screen = screens[screenIndex]
        targetArea = WindowMover.visibleArea(of: screen)
        guard let content else { return .zero }
        content.rootView = makeView()
        // Measure through the controller: an NSHostingView's fittingSize is zero until it has
        // been laid out in a window, which left the panel invisible at 0x0.
        return content.sizeThatFits(in: NSSize(width: 2000, height: 2000))
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
            showsSettings: showsSettings,
            hasSettingsFace: hasSettingsFace,
            buildSettingsFace: { [weak self] in self?.buildSettingsFace() },
            card: card,
            beginTurn: { [weak self] in self?.beginTurn() ?? .zero },
            endTurn: { [weak self] in self?.endTurn() },
            flipping: { [weak self] _ in self?.resizePreview.hide() },
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
    /// Whether the panel shows the settings (the back) instead of the grid.
    let showsSettings: Bool
    /// Whether the back exists yet: built on hovering the gear, or on the first flip at the latest.
    let hasSettingsFace: Bool
    let buildSettingsFace: () -> Void
    /// The card's angle and its offset in the panel, animated by the turn.
    let card: CardState
    /// Grows the panel for the turn and returns the card's offset at its end.
    let beginTurn: () -> CGSize
    /// Shrinks the panel to the face now showing.
    let endTurn: () -> Void
    /// Called with `true` as the card starts turning and `false` once it has landed.
    let flipping: (Bool) -> Void
    let cancel: () -> Void
    let openSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How shallow the turn's perspective is. Deeper looks more 3D but enlarges the near edge more.
    private static let perspective = 0.25
    /// Clear space around the card for its near edge, enlarged by perspective mid-turn, so it isn't
    /// clipped by the panel. At most (1 / (1 - perspective / 2) - 1) / 2 of the card's height: 48pt
    /// covers the 620pt settings. Clear pixels let clicks through to whatever is below.
    static let turnMargin: CGFloat = 48

    /// The panel size for the settings face: the settings window's, plus the margin for the turn.
    static var settingsFaceSize: NSSize {
        NSSize(width: SettingsView.size.width + 2 * turnMargin, height: SettingsView.size.height + 2 * turnMargin)
    }

    var body: some View {
        FaceStack(showing: showsSettings ? 1 : 0) {
            front
                .padding(16)
                .frame(width: width)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .modifier(CardShadow())
                .faceShown(!showsSettings)
                .modifier(CardFace(angle: card.angle, isBack: false, perspective: Self.perspective, crossFades: reduceMotion))
            if hasSettingsFace {
                settings
                    .modifier(CardShadow())
                    .faceShown(showsSettings)
                    .modifier(CardFace(angle: card.angle, isBack: true, perspective: Self.perspective, crossFades: reduceMotion))
            }
        }
        .offset(card.offset)
        .padding(Self.turnMargin)
    }

    /// Turns the card over in one half-turn, the new face coming in as the old one goes edge-on.
    /// Going back turns the other way, so the grid comes back the way it left.
    private func flip() {
        guard hasSettingsFace else {
            // Usually built already, from hovering the gear. If not, a pass for the new back to lay
            // out, hidden, so the turn doesn't stall on it. The turn only reads what the build
            // leaves alone, so this copy of the view can still run it.
            buildSettingsFace()
            DispatchQueue.main.async { turn() }
            return
        }
        turn()
    }

    /// The panel is resized before and after the turn, never during it: swapping faces and resizing
    /// with the card edge-on left it invisible for a tenth of a second or more.
    private func turn() {
        flipping(true)
        let offset = beginTurn()
        // A pass for the grown panel to draw before anything moves.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.42)) {
                card.angle = card.angle < 90 ? 180 : 0
                card.offset = offset
            } completion: {
                endTurn()
                flipping(false)
            }
        }
    }

    /// The settings window's content, on the back of the card.
    private var settings: some View {
        SettingsView(store: store, updater: updater)
            .overlay(alignment: .topLeading) {
                // Where the settings window has its traffic lights.
                Button("Back to the Grid", systemImage: "chevron.backward", action: flip)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Back to the grid")
                    .padding(.top, 16)
                    .padding(.leading, 22)
            }
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
    }

    private var front: some View {
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
            Button("Settings", systemImage: "gearshape", action: flip)
                // Builds the back while the pointer is on its way to clicking, so the turn starts at once.
                .onHover { if $0 { buildSettingsFace() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Settings")
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

/// Both faces of the grid panel, each at its own size and centred, sized to the face showing. Once
/// built, both stay in the view tree, so a flip never inserts views: Liquid Glass grows newly
/// inserted views into place, and the settings would lay themselves out while turning in. The back
/// is added hidden before the first flip starts; a flip only turns the card, each face drawn while
/// it faces the viewer.
struct FaceStack: Layout {
    var showing: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.indices.contains(showing) ? subviews[showing].sizeThatFits(.unspecified) : .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
        }
    }
}

private extension View {
    /// The face not showing stays laid out but can't be seen, clicked, focused or read out.
    func faceShown(_ shown: Bool) -> some View {
        allowsHitTesting(shown)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }
}

/// The connected screens as a row of icons, the main screen first. Clicking one points the grid at
/// that screen.
struct ScreenPicker: View {
    struct Screen {
        /// In Accessibility coordinates.
        let frame: CGRect
        let name: String
    }

    /// Indexes into `screens`, as `NSScreen.screens` lists them: 0 is the main screen.
    let screens: [Screen]
    let selected: Int
    let onSelect: (Int) -> Void
    let onHover: (Int?) -> Void

    /// The icons' height; with the platter's padding the picker is as tall as the gear button.
    private let height: CGFloat = 18

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScreenLayout.pickerOrder(of: screens.map(\.frame)), id: \.self) { index in
                let screen = screens[index]
                let isSelected = index == selected
                Button { onSelect(index) } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.22)))
                        .overlay(alignment: .top) {
                            // The menu bar, as System Settings → Displays marks the main screen.
                            if index == 0 {
                                Rectangle().fill(.white.opacity(0.8)).frame(height: 2.5)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 2.5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The panel is key while open: a focusable icon would wear the focus ring from the start.
                .focusable(false)
                // Each icon keeps its screen's shape, within limits so a portrait or ultrawide one stays usable.
                .frame(width: min(max(height * screen.frame.width / max(screen.frame.height, 1), 12), 64), height: height)
                .onHover { onHover($0 ? index : nil) }
                .help(index == 0 ? "\(screen.name) (main screen)" : screen.name)
                .accessibilityLabel("Place on \(screen.name)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 9))
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

/// The card's turn, 0 for the grid face up and 180 for the settings, and its offset in the panel.
@MainActor @Observable final class CardState {
    var angle: Double = 0
    var offset: CGSize = .zero
}

/// The card's shadow, drawn under each face so it turns with it. Only outside the card: the glass
/// is translucent and would show the shape casting it. Kept within `GridPanelView.turnMargin`.
private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            shape.fill(.black)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .mask {
                    Rectangle()
                        .padding(-GridPanelView.turnMargin)
                        .overlay { shape.blendMode(.destinationOut) }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
        }
    }
}

/// One face of the card: turned with it (the back half a turn further), and drawn only while it
/// faces the viewer. Animatable, so the face is hidden on the exact frame it passes edge-on.
/// With Reduce Motion the faces cross-fade in place instead: a turn through depth is the kind of
/// motion that setting is for.
private struct CardFace: ViewModifier, Animatable {
    var angle: Double
    let isBack: Bool
    let perspective: Double
    let crossFades: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        if crossFades {
            let progress = angle / 180
            content.opacity(isBack ? progress : 1 - progress)
        } else {
            turned(content)
        }
    }

    private func turned(_ content: Content) -> some View {
        let facing = isBack ? angle > 90 : angle < 90
        return content
            .rotation3DEffect(.degrees(isBack ? angle - 180 : angle), axis: (x: 0, y: 1, z: 0), perspective: perspective)
            .opacity(facing ? 1 : 0)
    }
}
