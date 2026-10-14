import PanesCore
import ServiceManagement
import SwiftUI

enum SettingsPage: Hashable {
    case general
    case preset(UUID)
}

struct SettingsView: View {
    /// The settings window's fixed content size.
    static let size = CGSize(width: 900, height: 620)
    /// Wide enough for a name like "Bottom" plus its shortcut; longer names end in "…".
    static let sidebarWidth: CGFloat = 240

    @Bindable var store: Store
    @State private var page: SettingsPage?
    /// The last page shown, so the window reopens where it was left: "general" or a preset id.
    @AppStorage("settingsPage") private var savedPage = "general"

    var body: some View {
        // A fixed layout rather than NavigationSplitView: in a non-resizable window the split view
        // ignored its column width and squeezed the preset names.
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(10)

            Group {
                switch page {
                case let .preset(id):
                    if let index = store.config.presets.firstIndex(where: { $0.id == id }) {
                        PresetEditor(store: store, preset: $store.config.presets[index],
                                     onDuplicate: { duplicate(id) }, onDelete: { delete(id) })
                            .id(id)
                    } else {
                        GeneralPane(store: store)
                    }
                case .general, nil:
                    GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GlassBackdrop())
        .ignoresSafeArea()
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            if page == nil {
                page = UUID(uuidString: savedPage).map(SettingsPage.preset) ?? .general
            }
        }
        .onChange(of: page) { _, page in
            if case let .preset(id) = page { savedPage = id.uuidString } else { savedPage = "general" }
        }
        .onDeleteCommand {
            if case let .preset(id) = page { delete(id) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $page) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsPage.general)

                Section("Presets") {
                    ForEach(store.config.presets) { preset in
                        PresetRow(preset: preset, shortcut: store.display(preset.key),
                                  hasIssue: !store.issues(for: preset.id).isEmpty || store.refusedHotkeys.contains(preset.id))
                            .tag(SettingsPage.preset(preset.id))
                            .contextMenu {
                                Button("Duplicate") { duplicate(preset.id) }
                                Button("Delete", role: .destructive) { delete(preset.id) }
                            }
                    }
                    .onMove { store.config.presets.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Button("New Preset", systemImage: "plus") {
                withAnimation { page = .preset(store.addPreset()) }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut("n")
            .padding(12)
        }
        // Room for the window's traffic lights, which float over the sidebar.
        .padding(.top, 40)
    }

    private func duplicate(_ id: UUID) {
        if let copy = store.duplicatePreset(id) { page = .preset(copy) }
    }

    private func delete(_ id: UUID) {
        let presets = store.config.presets
        let index = presets.firstIndex { $0.id == id } ?? 0
        withAnimation { store.deletePreset(id) }
        let remaining = store.config.presets
        page = remaining.isEmpty ? .general : .preset(remaining[min(index, remaining.count - 1)].id)
    }
}

struct PresetRow: View {
    let preset: Config.Preset
    let shortcut: String?
    let hasIssue: Bool

    var body: some View {
        HStack(spacing: 10) {
            GridThumbnail(area: preset.area, tint: preset.enabled ? .accentColor : .secondary)
                .frame(width: 30)
            Text(preset.name)
                .lineLimit(1)
                .foregroundStyle(preset.enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if hasIssue {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preset editor

struct PresetEditor: View {
    let store: Store
    @Binding var preset: Config.Preset
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var screenAspect: CGFloat = {
        let frame = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 16, height: 10)
        return frame.width / max(frame.height, 1)
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    TextField("Preset name", text: $preset.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Toggle("Enabled", isOn: $preset.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(preset.enabled ? "Enabled" : "Disabled: no shortcut, not in the grid panel")
                }

                GlassCard(title: "Area", systemImage: "rectangle.split.3x3") {
                    Text("Drag across the grid to choose where the window goes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    GridSelector(columns: preset.area.columns, rows: preset.area.rows, committed: preset.area) {
                        preset.area = $0
                    }
                    .aspectRatio(screenAspect, contentMode: .fit)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 24) {
                        Stepper(value: gridBinding(\.columns), in: Config.gridSizeRange) {
                            LabeledContent("Columns", value: "\(preset.area.columns)")
                        }
                        Stepper(value: gridBinding(\.rows), in: Config.gridSizeRange) {
                            LabeledContent("Rows", value: "\(preset.area.rows)")
                        }
                        Spacer()
                        Text(percentages.size)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(percentages.position)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                GlassCard(title: "Shortcut", systemImage: "keyboard") {
                    ShortcutRecorder(key: $preset.key, store: store, placeholder: "No shortcut")
                    if store.refusedHotkeys.contains(preset.id) {
                        IssueLabel(message: "Another app already uses this shortcut. Quit it (Divvy?) or pick another.")
                    }
                    ForEach(store.issues(for: preset.id), id: \.self) { IssueLabel(message: $0) }
                    Text("Without a shortcut, the preset is still a button in the grid panel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                    Spacer()
                    Button("Delete Preset", systemImage: "trash", role: .destructive, action: onDelete)
                        .tint(.red)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            // AppKit focuses the first text field, which selects the whole name: one keystroke
            // would replace it. Start with nothing focused instead.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    /// Changing the grid keeps the same part of the screen selected, as closely as the new grid allows.
    private func gridBinding(_ keyPath: WritableKeyPath<Config.GridSize, Int>) -> Binding<Int> {
        Binding {
            Config.GridSize(columns: preset.area.columns, rows: preset.area.rows)[keyPath: keyPath]
        } set: { value in
            var size = Config.GridSize(columns: preset.area.columns, rows: preset.area.rows)
            size[keyPath: keyPath] = value
            withAnimation(.snappy) { preset.area = preset.area.resized(columns: size.columns, rows: size.rows) }
        }
    }

    /// The area as screen percentages: its size, and its top-left corner for the tooltip.
    private var percentages: (size: String, position: String) {
        let a = preset.area
        let x = Double(a.minColumn) / Double(a.columns), w = Double(a.maxColumn - a.minColumn + 1) / Double(a.columns)
        let y = Double(a.minRow) / Double(a.rows), h = Double(a.maxRow - a.minRow + 1) / Double(a.rows)
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        return ("\(pct(w)) × \(pct(h)) of the screen", "Top-left corner at \(pct(x)), \(pct(y))")
    }
}

// MARK: - General

struct GeneralPane: View {
    @Bindable var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var confirmImport = false
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Panes")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                accessibilityCard

                GlassCard(title: "Grid Panel", systemImage: "square.grid.3x3") {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper(value: $store.config.grid.columns, in: Config.gridSizeRange) {
                                LabeledContent("Columns", value: "\(store.config.grid.columns)")
                            }
                            Stepper(value: $store.config.grid.rows, in: Config.gridSizeRange) {
                                LabeledContent("Rows", value: "\(store.config.grid.rows)")
                            }
                            Toggle("Show resize preview", isOn: $store.config.showResizePreview)
                                .toggleStyle(.switch)
                                .help("While you drag across the grid or hover a preset, outline where the window will land.")
                                .padding(.bottom, 6)
                            Text("Hotkey to open the grid for the frontmost window")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ShortcutRecorder(key: gridHotkey, store: store, placeholder: "Menu bar only")
                            if store.refusedHotkeys.contains(nil) {
                                IssueLabel(message: "Another app already uses this shortcut.")
                            }
                            ForEach(store.issues(for: nil), id: \.self) { IssueLabel(message: $0) }
                        }
                        .frame(width: 240)

                        GridSelector(columns: store.config.grid.columns, rows: store.config.grid.rows) { _ in }
                            .aspectRatio(16 / 10, contentMode: .fit)
                            .frame(maxWidth: 280)
                            .allowsHitTesting(false)
                    }
                }

                GlassCard(title: "Startup", systemImage: "power") {
                    Toggle("Open Panes at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let launchError { IssueLabel(message: launchError) }
                }

                GlassCard(title: "Presets File", systemImage: "doc.text") {
                    Text(Store.fileURL.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Store.fileURL])
                        }
                        if Store.hasDivvyPreferences {
                            Button("Import from Divvy…", systemImage: "square.and.arrow.down") { confirmImport = true }
                        }
                    }
                    .buttonStyle(.glass)
                    if let importError { IssueLabel(message: importError) }
                    if let saveError = store.saveError { IssueLabel(message: "Couldn't save: \(saveError)") }
                }
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Replace all presets with Divvy's?", isPresented: $confirmImport) {
            Button("Replace Presets", role: .destructive) {
                do {
                    try store.replaceWithDivvyImport()
                    importError = nil
                } catch {
                    importError = "Divvy's shortcuts couldn't be read."
                }
            }
        } message: {
            Text("Your current presets and grid size are replaced by the ones saved in Divvy.")
        }
    }

    private var accessibilityCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let trusted = WindowMover.isTrusted
            GlassCard(title: "Accessibility", systemImage: "hand.raised") {
                HStack(spacing: 12) {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted
                        ? "Panes can move windows."
                        : "Panes needs Accessibility access to move other apps' windows.")
                    Spacer()
                    if !trusted {
                        Button("Open Settings") {
                            WindowMover.requestTrust()
                            WindowMover.openAccessibilitySettings()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    private var gridHotkey: Binding<String> {
        Binding { store.config.gridHotkey ?? "" } set: { store.config.gridHotkey = $0.isEmpty ? nil : $0 }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
