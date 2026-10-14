import Foundation

/// The on-disk configuration, `~/Library/Application Support/Panes/config.json`.
public struct Config: Codable, Equatable, Sendable {
    public struct Preset: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        /// e.g. `ctrl+opt+cmd+left` (see `KeyCombo.init(parsing:layout:)`); empty for a preset that
        /// is only offered as a button in the grid panel.
        public var key: String
        public var enabled: Bool
        public var area: GridSelection

        public init(id: UUID = UUID(), name: String, key: String, enabled: Bool = true, area: GridSelection) {
            self.id = id
            self.name = name
            self.key = key
            self.enabled = enabled
            self.area = area
        }

        // A hand-written config may leave out `id` and `enabled`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decode(String.self, forKey: .name)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            area = try c.decode(GridSelection.self, forKey: .area)
        }
    }

    public struct GridSize: Codable, Equatable, Sendable {
        public var columns: Int
        public var rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }

        /// The same size, brought into `gridSizeRange`.
        public var clamped: GridSize {
            func clamp(_ value: Int) -> Int { min(max(value, gridSizeRange.lowerBound), gridSizeRange.upperBound) }
            return GridSize(columns: clamp(columns), rows: clamp(rows))
        }

        // The panel draws one view per cell: a hand-edited 0 or 10000 must not reach it.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = GridSize(columns: try c.decode(Int.self, forKey: .columns),
                            rows: try c.decode(Int.self, forKey: .rows)).clamped
        }
    }

    public static let gridSizeRange = 1...24

    /// The grid shown by the menu-bar panel.
    public var grid: GridSize
    /// Optional global shortcut that opens the grid panel for the frontmost window.
    public var gridHotkey: String?
    public var presets: [Preset]
    /// While dragging across the grid (or hovering a preset), outline on screen where the window will land.
    public var showResizePreview: Bool
    /// Ask GitHub once a day whether a newer release exists.
    public var checkForUpdates: Bool
    /// Pressing a preset's shortcut again, with the window still where it put it, moves the window to
    /// the same area of the next screen.
    public var cycleScreens: Bool

    public init(grid: GridSize, gridHotkey: String? = nil, presets: [Preset], showResizePreview: Bool = true,
                checkForUpdates: Bool = true, cycleScreens: Bool = false) {
        self.grid = grid
        self.gridHotkey = gridHotkey
        self.presets = presets
        self.showResizePreview = showResizePreview
        self.checkForUpdates = checkForUpdates
        self.cycleScreens = cycleScreens
    }

    // Fields added after the first release are optional, so older config files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grid = try c.decode(GridSize.self, forKey: .grid)
        gridHotkey = try c.decodeIfPresent(String.self, forKey: .gridHotkey)
        presets = try c.decode([Preset].self, forKey: .presets)
        showResizePreview = try c.decodeIfPresent(Bool.self, forKey: .showResizePreview) ?? true
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        cycleScreens = try c.decodeIfPresent(Bool.self, forKey: .cycleScreens) ?? false
    }

    /// Used when there is neither a config file nor a Divvy install to import from: the author's own
    /// setup, a 7-column layout of thirds and halves, plus a wide centre on a subdivided grid.
    public static var fallback: Config {
        func area(_ columns: Int, _ rows: Int, from start: (Int, Int), to end: (Int, Int)) -> GridSelection {
            GridSelection(columns: columns, rows: rows,
                          start: Cell(column: start.0, row: start.1), end: Cell(column: end.0, row: end.1))
        }
        return Config(
            grid: GridSize(columns: 6, rows: 6),
            gridHotkey: "ctrl+opt+cmd+space",
            presets: [
                Preset(name: "Center", key: "ctrl+opt+cmd+c", area: area(7, 6, from: (2, 0), to: (4, 5))),
                Preset(name: "Left", key: "ctrl+opt+cmd+left", area: area(7, 6, from: (0, 0), to: (1, 5))),
                Preset(name: "Right", key: "ctrl+opt+cmd+right", area: area(7, 6, from: (5, 0), to: (6, 5))),
                Preset(name: "Up", key: "ctrl+opt+cmd+up", area: area(7, 6, from: (2, 0), to: (4, 2))),
                Preset(name: "Down", key: "ctrl+opt+cmd+down", area: area(7, 6, from: (2, 3), to: (4, 5))),
                Preset(name: "Wide", key: "ctrl+opt+cmd+w", area: area(12, 12, from: (3, 0), to: (8, 11))),
            ],
            showResizePreview: true,
            checkForUpdates: true,
            cycleScreens: true
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    /// Problems that would make a preset or the grid unusable, keyed by preset id
    /// (`nil` for the grid and its hotkey) so the UI can show each next to its field.
    public func issues(layout: KeyLayout) -> [(preset: UUID?, message: String)] {
        var issues: [(UUID?, String)] = []
        if !Self.gridSizeRange.contains(grid.columns) || !Self.gridSizeRange.contains(grid.rows) {
            issues.append((nil, "The grid needs 1 to 24 columns and rows."))
        }
        var seen: [KeyCombo: String] = [:]
        if let gridHotkey, !gridHotkey.isEmpty {
            do { seen[try KeyCombo(parsing: gridHotkey, layout: layout)] = "the grid hotkey" } catch {
                issues.append((nil, "Grid hotkey: \(error)."))
            }
        }
        for preset in presets where preset.enabled {
            if !preset.area.isValid {
                issues.append((preset.id, "The area is outside its \(preset.area.columns)×\(preset.area.rows) grid."))
            }
            guard !preset.key.isEmpty else { continue }
            do {
                let combo = try KeyCombo(parsing: preset.key, layout: layout)
                if let other = seen[combo] {
                    issues.append((preset.id, "\(combo.displayString(layout: layout)) is already used by \(other)."))
                } else {
                    seen[combo] = "“\(preset.name)”"
                }
            } catch {
                issues.append((preset.id, "Shortcut: \(error)."))
            }
        }
        return issues
    }
}
