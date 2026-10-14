import CoreGraphics
import Foundation
import Testing
@testable import PanesCore

/// The layout the Divvy export came from: ABC-AZERTY, where key code 6 types "w".
let azerty = KeyLayout(characterForKeyCode: [0: "q", 6: "w", 8: "c", 12: "a", 13: "z"])

@Suite struct GridTests {
    let screen = CGRect(x: 0, y: 25, width: 1400, height: 875)

    @Test func centerThirdOfSevenColumns() {
        let center = GridSelection(columns: 7, rows: 6, start: Cell(column: 2, row: 0), end: Cell(column: 4, row: 5))
        #expect(center.frame(in: screen) == CGRect(x: 400, y: 25, width: 600, height: 875))
    }

    @Test func cornersInAnyOrder() {
        let a = GridSelection(columns: 4, rows: 4, start: Cell(column: 3, row: 3), end: Cell(column: 1, row: 2))
        let b = GridSelection(columns: 4, rows: 4, start: Cell(column: 1, row: 2), end: Cell(column: 3, row: 3))
        #expect(a.frame(in: screen) == b.frame(in: screen))
    }

    @Test func adjacentSelectionsTileWithoutGaps() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 700)
        let left = GridSelection(columns: 3, rows: 1, start: Cell(column: 0, row: 0), end: Cell(column: 0, row: 0))
        let rest = GridSelection(columns: 3, rows: 1, start: Cell(column: 1, row: 0), end: Cell(column: 2, row: 0))
        #expect(left.frame(in: odd).maxX == rest.frame(in: odd).minX)
        #expect(rest.frame(in: odd).maxX == 1001)
    }

    @Test func validity() {
        #expect(!GridSelection(columns: 2, rows: 2, start: Cell(column: 0, row: 0), end: Cell(column: 2, row: 0)).isValid)
        #expect(!GridSelection(columns: 0, rows: 2, start: Cell(column: 0, row: 0), end: Cell(column: 0, row: 0)).isValid)
    }

    @Test func flipBetweenAppKitAndAccessibility() {
        // A screen above-left of a 1000pt-tall primary display.
        let appKit = CGRect(x: -500, y: 1000, width: 500, height: 300)
        let ax = flipped(appKit, primaryScreenHeight: 1000)
        #expect(ax == CGRect(x: -500, y: -300, width: 500, height: 300))
        #expect(flipped(ax, primaryScreenHeight: 1000) == appKit)
    }
}

@Suite struct KeyComboTests {
    @Test func parsesNamedKeysAndModifiersInAnyOrder() throws {
        let combo = try KeyCombo(parsing: "cmd+ctrl+opt+left", layout: .usANSI)
        #expect(combo == KeyCombo(keyCode: 123, modifiers: [.command, .control, .option]))
    }

    @Test func characterKeysFollowTheLayout() throws {
        #expect(try KeyCombo(parsing: "ctrl+w", layout: azerty).keyCode == 6)
        #expect(try KeyCombo(parsing: "ctrl+w", layout: .usANSI).keyCode == 13)
    }

    @Test func roundTripsThroughConfigString() throws {
        for string in ["ctrl+opt+cmd+w", "shift+cmd+f12", "ctrl+opt+space", "ctrl+keycode99", "ctrl+keypad+"] {
            let combo = try KeyCombo(parsing: string, layout: azerty)
            #expect(try KeyCombo(parsing: combo.configString(layout: azerty), layout: azerty) == combo)
        }
    }

    @Test func display() throws {
        #expect(try KeyCombo(parsing: "cmd+opt+ctrl+up", layout: azerty).displayString(layout: azerty) == "⌃⌥⌘↑")
        #expect(try KeyCombo(parsing: "ctrl+opt+cmd+w", layout: azerty).displayString(layout: azerty) == "⌃⌥⌘W")
    }

    @Test func rejectsBadInput() {
        #expect(throws: KeyComboError.unknownModifier("hyper")) { try KeyCombo(parsing: "hyper+a", layout: .usANSI) }
        #expect(throws: KeyComboError.unknownKey("ü")) { try KeyCombo(parsing: "cmd+ü", layout: .usANSI) }
        #expect(throws: KeyComboError.noModifier("left")) { try KeyCombo(parsing: "left", layout: .usANSI) }
        #expect(throws: KeyComboError.empty) { try KeyCombo(parsing: "cmd+", layout: .usANSI) }
        #expect(throws: KeyComboError.unknownKey("+")) { try KeyCombo(parsing: "ctrl++", layout: .usANSI) }
        #expect(throws: KeyComboError.shiftOnly("shift+a")) { try KeyCombo(parsing: "shift+a", layout: .usANSI) }
        #expect(throws: KeyComboError.shiftOnly("shift+left")) { try KeyCombo(parsing: "shift+left", layout: .usANSI) }
    }

    @Test func shiftAloneIsEnoughOnFunctionKeys() throws {
        #expect(try KeyCombo(parsing: "shift+f5", layout: .usANSI) == KeyCombo(keyCode: 96, modifiers: .shift))
        #expect(KeyCombo.functionKeyCodes.count == 15)
    }

    @Test func cocoaFlagsFromDivvy() {
        // ⌃⌥⌘ plus the NSNumericPadKeyMask bit Cocoa sets on arrow keys.
        let combo = KeyCombo(keyCode: 124, cocoaFlags: 10_223_616)
        #expect(combo.modifiers == [.control, .option, .command])
    }
}

@Suite struct ConfigTests {
    let area = GridSelection(columns: 2, rows: 1, start: Cell(column: 0, row: 0), end: Cell(column: 0, row: 0))

    @Test func jsonRoundTrip() throws {
        let config = Config.fallback
        #expect(try Config.decode(config.encoded()) == config)
    }

    @Test func handWrittenPresetNeedsOnlyNameAndArea() throws {
        let json = #"{"grid":{"columns":4,"rows":4},"presets":[{"name":"Left","area":{"columns":2,"rows":1,"start":{"column":0,"row":0},"end":{"column":0,"row":0}}}]}"#
        let preset = try #require(try Config.decode(Data(json.utf8)).presets.first)
        #expect(preset.key == "" && preset.enabled)
    }

    @Test func configWithoutPreviewSettingDefaultsToOn() throws {
        let json = #"{"grid":{"columns":4,"rows":4},"presets":[]}"#
        #expect(try Config.decode(Data(json.utf8)).showResizePreview)
    }

    @Test func configWithoutUpdateSettingChecksForUpdates() throws {
        let json = #"{"grid":{"columns":4,"rows":4},"presets":[]}"#
        #expect(try Config.decode(Data(json.utf8)).checkForUpdates)
    }

    @Test func configWithoutCycleSettingKeepsWindowsOnTheirScreen() throws {
        let json = #"{"grid":{"columns":4,"rows":4},"presets":[]}"#
        #expect(try !Config.decode(Data(json.utf8)).cycleScreens)
    }

    @Test func handEditedGridSizesAreBroughtIntoRange() throws {
        let json = #"""
            {"grid":{"columns":0,"rows":100000},"presets":[{"name":"Odd","area":
              {"columns":0,"rows":480,"start":{"column":0,"row":240},"end":{"column":0,"row":479}}}]}
            """#
        let config = try Config.decode(Data(json.utf8))
        #expect(config.grid == .init(columns: 1, rows: 24))
        #expect(config.presets[0].area == GridSelection(columns: 1, rows: 48, start: Cell(column: 0, row: 24), end: Cell(column: 0, row: 47)))
    }

    @Test func fallbackIsValid() {
        #expect(Config.fallback.issues(layout: .usANSI).isEmpty)
        #expect(Config.fallback.issues(layout: azerty).isEmpty)
    }

    @Test func reportsDuplicateAndBrokenShortcutsPerPreset() {
        let a = Config.Preset(name: "A", key: "ctrl+opt+left", area: area)
        let b = Config.Preset(name: "B", key: "opt+ctrl+left", area: area)
        let c = Config.Preset(name: "C", key: "nonsense", area: area)
        let off = Config.Preset(name: "Off", key: "nonsense", enabled: false, area: area)
        let buttonOnly = Config.Preset(name: "Button", key: "", area: area)
        let issues = Config(grid: .init(columns: 6, rows: 6), presets: [a, b, c, off, buttonOnly]).issues(layout: .usANSI)
        #expect(issues.map(\.preset) == [b.id, c.id])
        #expect(issues[0].message == "⌃⌥← is already used by “A”.")
    }

    @Test func presetCannotStealTheGridHotkey() {
        let config = Config(grid: .init(columns: 6, rows: 6), gridHotkey: "ctrl+opt+space",
                            presets: [.init(name: "A", key: "opt+ctrl+space", area: area)])
        #expect(config.issues(layout: .usANSI).map(\.message) == ["⌃⌥Space is already used by the grid hotkey."])
    }
}

@Suite struct ResizeTests {
    @Test func keepsTheSameScreenArea() {
        let thirds = GridSelection(columns: 3, rows: 1, start: Cell(column: 1, row: 0), end: Cell(column: 2, row: 0))
        #expect(thirds.resized(columns: 6, rows: 2) == GridSelection(columns: 6, rows: 2, start: Cell(column: 2, row: 0), end: Cell(column: 5, row: 1)))
    }

    @Test func neverCollapsesOrOverflows() {
        let one = GridSelection(columns: 12, rows: 12, start: Cell(column: 11, row: 0), end: Cell(column: 11, row: 0))
        let small = one.resized(columns: 2, rows: 2)
        #expect(small.isValid)
        #expect(small.minColumn == 1 && small.maxColumn == 1 && small.minRow == 0 && small.maxRow == 0)
    }
}

@Suite struct ScreenTests {
    // Accessibility coordinates: a laptop as primary, a taller monitor to its left, one above it.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: -2560, y: -458, width: 2560, height: 1440)
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    var screens: [CGRect] { [laptop, left, above] }

    @Test func windowBelongsToTheScreenHoldingMostOfIt() {
        let straddling = CGRect(x: -300, y: 100, width: 1000, height: 600)
        #expect(ScreenLayout.index(holdingMostOf: straddling, in: screens) == 0)
        #expect(ScreenLayout.index(holdingMostOf: straddling.offsetBy(dx: -500, dy: 0), in: screens) == 1)
        #expect(ScreenLayout.index(holdingMostOf: CGRect(x: 5000, y: 0, width: 100, height: 100), in: screens) == nil)
    }

    @Test func nextScreenGoesLeftToRightThenTopToBottomAndWraps() {
        // Order: left (x -2560), above (x 0, y -1080), laptop (x 0, y 0).
        #expect(ScreenLayout.index(after: 1, in: screens) == 2)
        #expect(ScreenLayout.index(after: 2, in: screens) == 0)
        #expect(ScreenLayout.index(after: 0, in: screens) == 1)
        #expect(ScreenLayout.index(after: 0, in: [laptop]) == 0)
    }

    @Test func pickerListsThePrimaryScreenFirst() {
        #expect(ScreenLayout.pickerOrder(of: screens) == [0, 1, 2])
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(ScreenLayout.pickerOrder(of: [laptop, right, left]) == [0, 2, 1])
        #expect(ScreenLayout.pickerOrder(of: []) == [])
    }

    @Test func repeatedPlacementNeedsTheSameAppAreaAndFrame() {
        let half = GridSelection(columns: 2, rows: 1, start: Cell(column: 0, row: 0), end: Cell(column: 0, row: 0))
        let other = GridSelection(columns: 2, rows: 1, start: Cell(column: 1, row: 0), end: Cell(column: 1, row: 0))
        let placed = Placement(processID: 42, area: half, frame: CGRect(x: 0, y: 25, width: 756, height: 957))
        #expect(placed.isRepeated(area: half, processID: 42, frame: CGRect(x: 0.5, y: 25, width: 756, height: 957)))
        #expect(!placed.isRepeated(area: other, processID: 42, frame: placed.frame))
        #expect(!placed.isRepeated(area: half, processID: 7, frame: placed.frame))
        #expect(!placed.isRepeated(area: half, processID: 42, frame: placed.frame.offsetBy(dx: 40, dy: 0)))
    }
}

@Suite struct DivvyImportTests {
    /// Builds a keyed archive shaped like Divvy's: a root NSArray of `Shortcut` objects.
    func divvyPreferences() throws -> [String: Any] {
        let shortcuts = NSMutableArray()
        shortcuts.add(FakeShortcut(name: "Left", code: 123, flags: 10_223_616, columns: 7, rows: 6,
                                   start: (0, 0), end: (1, 5), subdivided: false))
        shortcuts.add(FakeShortcut(name: "Wide", code: 6, flags: 1_835_008, columns: 7, rows: 6,
                                   start: (3, 0), end: (10, 11), subdivided: true))
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("Shortcut", for: FakeShortcut.self)
        archiver.encode(shortcuts, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return [
            "shortcuts": archiver.encodedData,
            "useDefaultGrid": true, "defaultColumnCount": 7, "defaultRowCount": 6,
            "lastColumnCount": 8, "lastRowCount": 8,
        ]
    }

    @Test func importsShortcutsGridAndSubdivision() throws {
        let config = try DivvyImport.config(fromPreferences: divvyPreferences(), layout: azerty)
        #expect(config.grid == Config.GridSize(columns: 7, rows: 6))
        #expect(config.presets.map(\.name) == ["Left", "Wide"])
        #expect(config.presets[0].key == "ctrl+opt+cmd+left")
        #expect(config.presets[0].area == GridSelection(columns: 7, rows: 6, start: Cell(column: 0, row: 0), end: Cell(column: 1, row: 5)))
        #expect(config.presets[1].key == "ctrl+opt+cmd+w")
        #expect(config.presets[1].area == GridSelection(columns: 14, rows: 12, start: Cell(column: 3, row: 0), end: Cell(column: 10, row: 11)))
        #expect(config.issues(layout: azerty).isEmpty)
    }

    @Test func carriesOverDivvysPreviewSetting() throws {
        var prefs = try divvyPreferences()
        #expect(try DivvyImport.config(fromPreferences: prefs, layout: azerty).showResizePreview)
        prefs["showResizePreview"] = false
        #expect(try !DivvyImport.config(fromPreferences: prefs, layout: azerty).showResizePreview)
    }

    @Test func missingShortcuts() {
        #expect(throws: DivvyImport.Failure.noShortcuts) { try DivvyImport.config(fromPreferences: [:], layout: azerty) }
        #expect(throws: DivvyImport.Failure.unreadableArchive) {
            try DivvyImport.config(fromPreferences: ["shortcuts": Data("nope".utf8)], layout: azerty)
        }
    }
}

final class FakeShortcut: NSObject, NSCoding {
    let values: [String: Any]

    init(name: String, code: Int, flags: Int, columns: Int, rows: Int,
         start: (Int, Int), end: (Int, Int), subdivided: Bool) {
        values = [
            "nameKey": name, "keyComboCode": code, "keyComboFlags": flags, "enabled": true, "global": true,
            "sizeColumns": columns, "sizeRows": rows, "subdivided": subdivided,
            "selectionStartColumn": start.0, "selectionStartRow": start.1,
            "selectionEndColumn": end.0, "selectionEndRow": end.1,
        ]
    }

    func encode(with coder: NSCoder) {
        for (key, value) in values {
            switch value {
            case let v as Bool: coder.encode(v, forKey: key)
            case let v as Int: coder.encode(v, forKey: key)
            default: coder.encode(value, forKey: key)
            }
        }
    }

    init?(coder: NSCoder) { nil }
}

@Suite struct UpdateTests {
    func json(tag: String = "v1.2.0", asset: String = "Panes-1.2.0.dmg",
              url: String = "https://github.com/mp-consulting/panes/releases/download/v1.2.0/Panes-1.2.0.dmg") -> Data {
        Data(#"""
            {"tag_name":"\#(tag)","html_url":"https://github.com/mp-consulting/panes/releases/tag/\#(tag)",
             "draft":false,"assets":[{"name":"notes.txt","browser_download_url":"https://example.com/x"},
             {"name":"\#(asset)","browser_download_url":"\#(url)"}]}
            """#.utf8)
    }

    @Test func comparesVersionsNumerically() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("1.10.0") > v("1.9.0"))
        #expect(try v("v1.1") == v("1.1.0"))
        #expect(try v("2") > v("1.99.99"))
        #expect(try !(v("1.1.0") < v("1.1.0")))
        #expect(try v("v1.2.0").description == "1.2.0")
    }

    @Test func rejectsVersionsItCannotOrder() {
        for text in ["", "1..2", "1.2.0-beta", "latest", "v", "1.2.3.4.5", "-1.0"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func readsTheLatestRelease() throws {
        let release = try Release(gitHubJSON: json())
        #expect(release.version == AppVersion("1.2.0"))
        #expect(release.diskImageURL.absoluteString == "https://github.com/mp-consulting/panes/releases/download/v1.2.0/Panes-1.2.0.dmg")
        #expect(release.pageURL.absoluteString == "https://github.com/mp-consulting/panes/releases/tag/v1.2.0")
    }

    @Test func refusesImagesFromAnywhereElse() {
        #expect(throws: Release.Failure.noDiskImage) { try Release(gitHubJSON: json(asset: "Panes-1.1.0.dmg")) }
        #expect(throws: Release.Failure.noDiskImage) {
            try Release(gitHubJSON: json(url: "https://evil.example/mp-consulting/panes/releases/download/v1.2.0/Panes-1.2.0.dmg"))
        }
        #expect(throws: Release.Failure.noDiskImage) {
            try Release(gitHubJSON: json(url: "http://github.com/mp-consulting/panes/releases/download/v1.2.0/Panes-1.2.0.dmg"))
        }
        #expect(throws: Release.Failure.badVersion("nightly")) { try Release(gitHubJSON: json(tag: "nightly")) }
        #expect(throws: Release.Failure.unreadable) { try Release(gitHubJSON: Data("{}".utf8)) }
    }

    @Test func checksOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.interval), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
