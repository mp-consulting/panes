import Foundation

/// Reads Divvy's preferences (domain `com.mizage.direct.Divvy`, or `com.mizage.Divvy` for the
/// App Store build) into a `Config`.
///
/// Divvy keeps its shortcuts as an `NSKeyedArchiver` blob of `Shortcut` objects. The archive is
/// walked as a plain property list rather than unarchived, so no Divvy class has to exist here.
public enum DivvyImport {
    public enum Failure: Error, Equatable {
        case noShortcuts
        case unreadableArchive
    }

    public static func config(fromPreferences prefs: [String: Any], layout: KeyLayout) throws(Failure) -> Config {
        guard let blob = prefs["shortcuts"] as? Data else { throw .noShortcuts }
        let entries = try shortcutDictionaries(fromArchive: blob)

        let useDefault = (prefs["useDefaultGrid"] as? Bool) ?? true
        let columns = (prefs[useDefault ? "defaultColumnCount" : "lastColumnCount"] as? Int) ?? 6
        let rows = (prefs[useDefault ? "defaultRowCount" : "lastRowCount"] as? Int) ?? 6

        let presets = entries.compactMap { entry -> Config.Preset? in
            guard let sizeColumns = entry["sizeColumns"] as? Int, let sizeRows = entry["sizeRows"] as? Int,
                  let startColumn = entry["selectionStartColumn"] as? Int, let startRow = entry["selectionStartRow"] as? Int,
                  let endColumn = entry["selectionEndColumn"] as? Int, let endRow = entry["selectionEndRow"] as? Int,
                  let keyCode = entry["keyComboCode"] as? Int, let flags = entry["keyComboFlags"] as? Int
            else { return nil }
            // A subdivided grid has each cell split in two both ways; the selection is stored on that finer grid.
            let factor = (entry["subdivided"] as? Bool) == true ? 2 : 1
            let combo = KeyCombo(keyCode: UInt32(keyCode), cocoaFlags: UInt(flags))
            return Config.Preset(
                name: (entry["nameKey"] as? String) ?? "Shortcut",
                key: combo.configString(layout: layout),
                enabled: (entry["enabled"] as? Bool) ?? true,
                area: GridSelection(
                    columns: sizeColumns * factor, rows: sizeRows * factor,
                    start: Cell(column: startColumn, row: startRow),
                    end: Cell(column: endColumn, row: endRow)
                )
            )
        }
        guard !presets.isEmpty else { throw .noShortcuts }
        return Config(
            grid: Config.GridSize(columns: columns, rows: rows), presets: presets,
            showResizePreview: (prefs["showResizePreview"] as? Bool) ?? true
        )
    }

    /// Resolves the keyed archive's root array into one dictionary per `Shortcut`, with UIDs dereferenced.
    static func shortcutDictionaries(fromArchive blob: Data) throws(Failure) -> [[String: Any]] {
        guard let archive = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any],
              let top = archive["$top"] as? [String: Any]
        else { throw .unreadableArchive }

        func resolve(_ value: Any?) -> Any? {
            guard let value, let index = uidIndex(value), objects.indices.contains(index) else { return value }
            return objects[index]
        }

        guard let root = resolve(top["root"]) as? [String: Any],
              let members = root["NS.objects"] as? [Any]
        else { throw .unreadableArchive }

        return members.compactMap { member in
            guard let object = resolve(member) as? [String: Any] else { return nil }
            var entry: [String: Any] = [:]
            for (key, value) in object where key != "$class" {
                entry[key] = resolve(value)
            }
            return entry
        }
    }

    /// `PropertyListSerialization` surfaces `CF$UID` values as an opaque `__NSCFType` whose only
    /// public trace is its description: `<CFKeyedArchiverUID 0x… [0x…]>{value = 4}`.
    static func uidIndex(_ value: Any) -> Int? {
        guard !(value is String), !(value is NSNumber), !(value is Data) else { return nil }
        let text = String(describing: value)
        guard text.hasPrefix("<CFKeyedArchiverUID"), let range = text.range(of: "value = ") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }
}
