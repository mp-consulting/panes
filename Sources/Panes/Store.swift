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
            updateIssues()
            scheduleSave()
            onChange?()
        }
    }

    private(set) var layout: KeyLayout
    /// `Config.issues`, grouped by preset: the sidebar asks once per row, so it's computed per change.
    private var issuesByPreset: [UUID?: [String]] = [:]
    /// Presets whose shortcut the system refused, by id; `nil` key for the grid hotkey.
    var refusedHotkeys: Set<UUID?> = []
    /// Set to send the settings to the Updates card, from an "update available" button; cleared
    /// once they're there.
    var revealUpdates = false
    /// True while a shortcut recorder listens: hotkeys are suspended so the keys reach it.
    var isRecordingShortcut = false {
        didSet { if isRecordingShortcut != oldValue { onChange?() } }
    }
    private(set) var saveError: String?
    /// Set when `config.json` existed but couldn't be read; the file is kept under another name.
    private(set) var loadError: String?
    /// Whether this launch created the config (first run), so the app can show what it imported.
    private(set) var isFirstRun = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let layout = KeyboardLayout.current()
        self.layout = layout
        let data = try? Data(contentsOf: Self.fileURL)
        do {
            guard let data else { throw CocoaError(.fileReadNoSuchFile) }
            self.config = try Config.decode(data)
        } catch {
            if data != nil {
                // A hand-edited file with a typo: keep it so the edits aren't lost to the rewrite below.
                loadError = Self.setAsideUnreadableConfig(error)
            }
            self.config = (try? Self.importFromDivvy(layout: layout)) ?? .fallback
            isFirstRun = data == nil
            save()
        }
        updateIssues()
    }

    /// Renames the unreadable `config.json` and returns the message the settings show.
    private static func setAsideUnreadableConfig(_ error: Error) -> String {
        // Local time, so the name matches the clock of the person looking for the file.
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let kept = directory.appending(path: "config-unreadable-\(stamp).json")
        let reason = (error as? DecodingError).map(Self.describe) ?? error.localizedDescription
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
            return "config.json couldn't be read (\(reason)). It was kept as \(kept.lastPathComponent)."
        } catch {
            return "config.json couldn't be read (\(reason)) and was replaced."
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context), let .keyNotFound(_, context),
             let .typeMismatch(_, context), let .valueNotFound(_, context):
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            // Foundation's descriptions end in a full stop; the message wraps this one in parentheses.
            let detail = context.debugDescription.hasSuffix(".") ? String(context.debugDescription.dropLast()) : context.debugDescription
            return path.isEmpty ? detail : "\(path.joined(separator: ".")): \(detail)"
        @unknown default:
            return error.localizedDescription
        }
    }

    func issues(for preset: UUID?) -> [String] {
        issuesByPreset[preset] ?? []
    }

    private func updateIssues() {
        issuesByPreset = Dictionary(grouping: config.issues(layout: layout), by: \.preset).mapValues { $0.map(\.message) }
    }

    func display(_ key: String) -> String? {
        guard !key.isEmpty, let combo = try? KeyCombo(parsing: key, layout: layout) else { return nil }
        return combo.displayString(layout: layout)
    }

    func refreshKeyboardLayout() {
        layout = KeyboardLayout.current()
        updateIssues()
        onChange?()
    }

    // MARK: Presets

    @discardableResult
    func addPreset() -> UUID {
        let grid = config.grid
        let preset = Config.Preset(
            name: "New Preset", key: "",
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

    /// Puts a deleted preset back where it was, for undo.
    func insertPreset(_ preset: Config.Preset, at index: Int) {
        config.presets.insert(preset, at: min(index, config.presets.count))
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
