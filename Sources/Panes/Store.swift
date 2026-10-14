import AppKit
import Observation
import PanesCore

/// The app's single source of truth: the config (saved to disk on every change) and the
/// state the UI shows next to it.
@MainActor @Observable final class Store {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Panes", directoryHint: .isDirectory)
    static let fileURL = directory.appending(path: "config.json")
    static let divvyDomains = ["com.mizage.direct.Divvy", "com.mizage.Divvy"]

    var config: Config {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            onChange?()
        }
    }

    private(set) var layout: KeyLayout
    /// Presets whose shortcut the system refused, by id; `nil` key for the grid hotkey.
    var refusedHotkeys: Set<UUID?> = []
    /// True while a shortcut recorder listens: hotkeys are suspended so the keys reach it.
    var isRecordingShortcut = false {
        didSet { if isRecordingShortcut != oldValue { onChange?() } }
    }
    private(set) var saveError: String?
    /// Whether this launch created the config (first run), so the app can show what it imported.
    private(set) var isFirstRun = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let layout = KeyboardLayout.current()
        self.layout = layout
        if let data = try? Data(contentsOf: Self.fileURL), let config = try? Config.decode(data) {
            self.config = config
        } else {
            self.config = (try? Self.importFromDivvy(layout: layout)) ?? .fallback
            isFirstRun = true
            save()
        }
    }

    func issues(for preset: UUID?) -> [String] {
        config.issues(layout: layout).filter { $0.preset == preset }.map(\.message)
    }

    func display(_ key: String) -> String? {
        guard !key.isEmpty, let combo = try? KeyCombo(parsing: key, layout: layout) else { return nil }
        return combo.displayString(layout: layout)
    }

    func refreshKeyboardLayout() {
        layout = KeyboardLayout.current()
        onChange?()
    }

    // MARK: Presets

    @discardableResult
    func addPreset() -> UUID {
        let grid = config.grid
        let preset = Config.Preset(
            name: "New preset", key: "",
            area: GridSelection(columns: grid.columns, rows: grid.rows,
                                start: Cell(column: 0, row: 0), end: Cell(column: grid.columns - 1, row: grid.rows - 1))
        )
        config.presets.append(preset)
        return preset.id
    }

    @discardableResult
    func duplicatePreset(_ id: UUID) -> UUID? {
        guard let index = config.presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = config.presets[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.key = "" // a copy with the same shortcut would only produce a conflict
        config.presets.insert(copy, at: index + 1)
        return copy.id
    }

    func deletePreset(_ id: UUID) {
        config.presets.removeAll { $0.id == id }
    }

    // MARK: Divvy

    static var hasDivvyPreferences: Bool { divvyPreferences() != nil }

    func replaceWithDivvyImport() throws {
        config = try Self.importFromDivvy(layout: layout)
    }

    private static func divvyPreferences() -> [String: Any]? {
        divvyDomains.lazy.compactMap { UserDefaults.standard.persistentDomain(forName: $0) }
            .first { $0["shortcuts"] != nil }
    }

    private static func importFromDivvy(layout: KeyLayout) throws -> Config {
        guard let prefs = divvyPreferences() else { throw DivvyImport.Failure.noShortcuts }
        return try DivvyImport.config(fromPreferences: prefs, layout: layout)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try config.encoded().write(to: Self.fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }
}
