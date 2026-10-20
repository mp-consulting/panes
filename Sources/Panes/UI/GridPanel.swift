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
    private var panel: FloatingPanel?
    private var content: NSHostingController<GridPanelView>?
    private let resizePreview = ResizePreview()
    private var target: NSRunningApplication?
    /// Whether the target has a window to place: not the Finder with only the desktop, say.
    private var hasWindow = true
    /// Told when the panel opens and closes, for the menu-bar icon to show it.
    var visibilityChanged: ((Bool) -> Void)?
    /// The screens when the panel opened. It closes when they change, so these stay current.
    private var screens: [NSScreen] = []
    /// The screen the grid places the window on: the window's own at first, then the one picked.
    private var screenIndex = 0
    /// The screen the panel itself is on, which picking another screen doesn't change.
    private var hostScreen: NSScreen?
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
    /// Where the card was when the turn under way began, for turning it back mid-turn.
    private var frameBeforeTurn: NSRect?

    init(store: Store,
         updater: Updater,
         apply: @escaping (NSRunningApplication, GridSelection, NSScreen) -> Void) {
        self.store = store
        self.updater = updater
        self.apply = apply
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
        var windowFrame: CGRect?
        var hasWindow = target != nil
        if let target {
            do throws(WindowMover.Failure) {
                windowFrame = try WindowMover.focusedWindow(of: target).frame
            } catch {
                // Without Accessibility there's no telling; the panel says so separately.
                if case .noWindow = error { hasWindow = false }
            }
        }
        guard let screen = windowFrame.flatMap(WindowMover.screen(for:)) ?? NSScreen.main ?? screens.first
        else { return NSSound.beep() }
        self.target = target
        self.hasWindow = hasWindow
        self.screens = screens
        showsSettings = false
        hasSettingsFace = false
        card = CardState()
        frameAfterTurn = nil
        frameBeforeTurn = nil
        screenIndex = screens.firstIndex { $0.frame == screen.frame } ?? 0
        hostScreen = screen

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
        // Opened by a hotkey many times a day: it's there at once, like a menu.
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.setFrame(clamped(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                      width: size.width, height: size.height), on: screen),
                       display: false)
        panel.makeKeyAndOrderFront(nil)
        // Nothing focused to start with: AppKit gives focus to the first control that takes it,
        // and with the settings not yet built on the back, that is the gear, ringed from the start.
        // Escape still reaches the panel through `cancelOperation`.
        panel.makeFirstResponder(nil)
        self.panel = panel
        visibilityChanged?(true)
    }

    func close() {
        resizePreview.hide()
        if panel != nil { visibilityChanged?(false) }
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
        panel.setFrame(clamped(NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height),
                               on: panel.screen ?? hostScreen),
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
        let size = showsSettings ? settingsFaceSize : layOut()
        let old = panel.frame
        let new = clamped(NSRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height),
                          on: panel.screen ?? hostScreen)
        let union = old.union(new)
        frameAfterTurn = new
        frameBeforeTurn = old
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
        frameBeforeTurn = nil
        card.offset = .zero
        panel.setFrame(frame, display: true)
    }

    /// Mid-turn: sends the card back where it came from and returns its offset there, or `nil`
    /// when no turn is under way. The panel already holds both the frame the card left and the one
    /// it was heading for, so nothing is resized: only the faces' roles swap.
    private func reverseTurn() -> CGSize? {
        guard let panel, let back = frameBeforeTurn, let ahead = frameAfterTurn else { return nil }
        showsSettings.toggle()
        (frameBeforeTurn, frameAfterTurn) = (ahead, back)
        // Which face takes clicks; both are built and laid out, so this moves nothing.
        content?.rootView = makeView()
        let union = panel.frame
        return CGSize(width: back.midX - union.midX, height: union.midY - back.midY)
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

    /// The tallest the card may be: its screen's height, menu bar and Dock excluded, less a little air.
    private var maxCardHeight: CGFloat {
        (hostScreen ?? NSScreen.main).map { $0.visibleFrame.height - 16 } ?? 2000
    }

    /// The panel size for the settings face: the settings at the height its screen allows, plus the
    /// margin for the turn.
    private var settingsFaceSize: NSSize {
        let size = SettingsView.size(on: hostScreen)
        return NSSize(width: size.width + 2 * GridPanelView.turnMargin, height: size.height + 2 * GridPanelView.turnMargin)
    }

    /// Where a panel frame goes on `screen`: all of it on screen when it fits, otherwise the card,
    /// the clear margin for the turn running off the edge, and failing that the card's top and left.
    private func clamped(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
        let margin = GridPanelView.turnMargin
        func place(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat, keepUpper: Bool) -> CGFloat {
            var (lower, upper) = (lower, upper)
            if length > upper - lower { (lower, upper) = (lower - margin, upper + margin) }
            if length > upper - lower { return keepUpper ? upper - length : lower }
            return min(max(origin, lower), upper - length)
        }
        var frame = frame
        frame.origin.x = place(frame.minX, frame.width, visible.minX, visible.maxX, keepUpper: false)
        // AppKit's y axis points up: the upper end is the top.
        frame.origin.y = place(frame.minY, frame.height, visible.minY, visible.maxY, keepUpper: true)
        return frame
    }

    /// Rebuilds the content for the selected screen and returns the panel size it needs. A card
    /// taller than its screen (dozens of presets) is measured again with the presets scrolling in
    /// what room is left.
    private func layOut() -> NSSize {
        let screen = screens[screenIndex]
        targetArea = WindowMover.visibleArea(of: screen)
        guard let content else { return .zero }
        // Measure through the controller: an NSHostingView's fittingSize is zero until it has
        // been laid out in a window, which left the panel invisible at 0x0.
        func measure(presetsHeight: CGFloat?) -> NSSize {
            content.rootView = makeView(presetsHeight: presetsHeight)
            return content.sizeThatFits(in: NSSize(width: 2000, height: 4000))
        }
        let size = measure(presetsHeight: nil)
        let maxHeight = maxCardHeight + 2 * GridPanelView.turnMargin
        guard size.height > maxHeight else { return size }
        let withoutPresets = measure(presetsHeight: 0).height
        return measure(presetsHeight: max(maxHeight - withoutPresets, 60))
    }

    private func makeView(presetsHeight: CGFloat? = nil) -> GridPanelView {
        let target = target
        let screen = screens[screenIndex].visibleFrame
        let aspect = screen.width / max(screen.height, 1)
        // Wide screens get a wider panel, so the grid keeps a usable height (~230pt).
        let width = min(max(230 * aspect + 32, 380), 760)
        return GridPanelView(
            store: store, updater: updater, target: target, hasWindow: hasWindow, aspect: aspect,
            width: width,
            // A portrait screen's grid would be taller than a short screen: it narrows instead,
            // keeping room for the header and a row of presets.
            gridHeight: min((width - 32) / max(aspect, 0.5), max(maxCardHeight - 200, 160)),
            presetsHeight: presetsHeight,
            settingsHeight: SettingsView.size(on: hostScreen).height,
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
            reverseTurn: { [weak self] in self?.reverseTurn() },
            endTurn: { [weak self] in self?.endTurn() },
            flipping: { [weak self] _ in self?.resizePreview.hide() },
            cancel: { [weak self] in self?.close() }
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
    let hasWindow: Bool
    let aspect: CGFloat
    let width: CGFloat
    let gridHeight: CGFloat
    /// When set, the preset buttons scroll in this height: there are too many for the screen.
    let presetsHeight: CGFloat?
    let settingsHeight: CGFloat
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
    /// Mid-turn, sends the card back and returns its offset there; `nil` when no turn is under way.
    let reverseTurn: () -> CGSize?
    /// Shrinks the panel to the face now showing.
    let endTurn: () -> Void
    /// Called with `true` as the card starts turning and `false` once it has landed.
    let flipping: (Bool) -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How shallow the turn's perspective is. Deeper looks more 3D but enlarges the near edge more.
    private static let perspective = 0.25
    /// Clear space around the card for its near edge, enlarged by perspective mid-turn, so it isn't
    /// clipped by the panel. At most (1 / (1 - perspective / 2) - 1) / 2 of the card's height: 48pt
    /// covers the 620pt settings. Clear pixels let clicks through to whatever is below.
    static let turnMargin: CGFloat = 48

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
        // The incoming face takes clicks as soon as the turn starts. A click then turns the card
        // back from wherever it has got to, with no resize: SwiftUI's animations add up, so the
        // reversal starts from the angle and speed on screen.
        if let offset = reverseTurn() { return animateTurn(to: offset) }
        let offset = beginTurn()
        // A pass for the grown panel to draw before anything moves.
        DispatchQueue.main.async { animateTurn(to: offset) }
    }

    private func animateTurn(to offset: CGSize) {
        card.turns += 1
        let turn = card.turns
        withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.42)) {
            card.angle = card.angle < 90 ? 180 : 0
            card.offset = offset
        } completion: {
            // A turn reversed midway finishes after its reversal began: only the last one lands.
            guard card.turns == turn else { return }
            endTurn()
            flipping(false)
        }
    }

    /// The settings window's content, on the back of the card.
    private var settings: some View {
        SettingsView(store: store, updater: updater, height: settingsHeight)
            .overlay(alignment: .topLeading) {
                // Where the settings window has its traffic lights.
                Button("Back to the Grid", systemImage: "chevron.backward", action: flip)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Back to the Grid")
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
                .frame(width: min(width - 32, gridHeight * max(aspect, 0.5)), height: gridHeight)
                .frame(maxWidth: .infinity)
                // Nothing to place: a drag would only close the panel and beep.
                .allowsHitTesting(hasWindow)
                .opacity(hasWindow ? 1 : 0.45)

            // Same rule as the hotkeys: an area outside its grid would place the window off screen.
            let presets = store.config.presets.filter { $0.enabled && $0.area.isValid }
            if !presets.isEmpty {
                let buttons = GlassEffectContainer(spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        ForEach(presets) { preset in
                            PresetButton(preset: preset, shortcut: store.display(preset.key)) { apply(preset.area) }
                                .onHover { preview($0 ? preset.area : nil) }
                        }
                    }
                }
                Group {
                    if let presetsHeight {
                        ScrollView { buttons }
                            .frame(height: presetsHeight)
                    } else {
                        buttons
                    }
                }
                .disabled(!hasWindow)
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
                .help(target?.localizedName ?? "")
            if target != nil, !hasWindow {
                Text("No window to place")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if screens.count > 1 {
                ScreenPicker(screens: screens, selected: selectedScreen, onSelect: selectScreen, onHover: previewScreen)
            }
            if let release = updater.availableRelease {
                // Turns to the settings like the gear beside it, opened at the Updates card.
                Button("Update", systemImage: "arrow.down.circle.fill") {
                    store.revealUpdates = true
                    flip()
                }
                .onHover { if $0 { buildSettingsFace() } }
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
        let order = ScreenLayout.pickerOrder(of: screens.map(\.frame))
        // Past three screens the icons narrow, so the header keeps room for the app's name.
        let widest = screens.count > 3 ? max(160 / CGFloat(screens.count), 24) : 64
        // No gaps between the icons: hovering across a gap faded the screen outline out and back in.
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { index in
                let screen = screens[index]
                let isSelected = index == selected
                let name = Self.name(of: index, in: screens, order: order)
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
                        // Each icon keeps its screen's shape, within limits so a portrait or ultrawide one stays usable.
                        .frame(width: min(max(height * screen.frame.width / max(screen.frame.height, 1), 12), widest), height: height)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScreenIconStyle())
                // The panel is key while open: a focusable icon would wear the focus ring from the start.
                .focusable(false)
                .onHover { onHover($0 ? index : nil) }
                .help(index == 0 ? "\(name) (main screen)" : name)
                .accessibilityLabel(name)
                .accessibilityHint("Points the grid at this screen")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: .capsule)
    }

    /// The screen's name, numbered in picker order when another screen has the same one (two of the
    /// same monitor).
    private static func name(of index: Int, in screens: [Screen], order: [Int]) -> String {
        let name = screens[index].name
        let twins = order.filter { screens[$0].name == name }
        guard twins.count > 1, let position = twins.firstIndex(of: index) else { return name }
        return "\(name) (\(position + 1))"
    }
}

/// A screen icon dims while pressed, like any button.
private struct ScreenIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
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
                    Text(preset.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    if let shortcut {
                        Text(shortcut).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        // The name is cut short in a narrow button.
        .help(preset.displayName)
    }
}

/// The card's turn, 0 for the grid face up and 180 for the settings, and its offset in the panel.
@MainActor @Observable final class CardState {
    var angle: Double = 0
    var offset: CGSize = .zero
    /// Counts turns, reversals included, so only the latest one's completion ends the turn.
    @ObservationIgnored var turns = 0
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
