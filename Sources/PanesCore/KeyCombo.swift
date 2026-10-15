/// A global shortcut: a virtual key code (a physical key position) plus modifiers.
///
/// In the config file it is written as a string such as `"ctrl+opt+cmd+left"` or `"ctrl+opt+cmd+w"`.
/// Character keys are resolved against the active keyboard layout, so `w` means the key that
/// types "w" (key code 6 on AZERTY, 13 on QWERTY). The layout is injected as a `KeyLayout` so this
/// file stays free of Carbon and testable.
public struct KeyCombo: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        // Carbon modifier bits, as RegisterEventHotKey expects them.
        public static let command = Modifiers(rawValue: 0x0100)
        public static let shift = Modifiers(rawValue: 0x0200)
        public static let option = Modifiers(rawValue: 0x0800)
        public static let control = Modifiers(rawValue: 0x1000)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a combo from Cocoa `NSEvent.ModifierFlags` raw bits, the format Divvy stored.
    public init(keyCode: UInt32, cocoaFlags: UInt) {
        var modifiers: Modifiers = []
        if cocoaFlags & 0x20000 != 0 { modifiers.insert(.shift) }
        if cocoaFlags & 0x40000 != 0 { modifiers.insert(.control) }
        if cocoaFlags & 0x80000 != 0 { modifiers.insert(.option) }
        if cocoaFlags & 0x100000 != 0 { modifiers.insert(.command) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

/// Maps character keys to key codes for one keyboard layout. Non-character keys
/// (arrows, F-keys, space…) don't depend on the layout and are handled by `KeyCombo` itself.
public struct KeyLayout: Sendable {
    public let characterForKeyCode: [UInt32: String]
    /// The reverse map, built once: every shortcut parse looks a character up.
    private let keyCodeForCharacter: [String: UInt32]

    public init(characterForKeyCode: [UInt32: String]) {
        self.characterForKeyCode = characterForKeyCode
        // Several codes can type the same character (main row and keypad); keep the lowest.
        keyCodeForCharacter = Dictionary(characterForKeyCode.map { ($1, $0) }, uniquingKeysWith: min)
    }

    public func keyCode(for character: String) -> UInt32? {
        keyCodeForCharacter[character]
    }

    /// US ANSI, for tests and as a fallback when the layout can't be read.
    public static let usANSI = KeyLayout(characterForKeyCode: [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ])
}

public enum KeyComboError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownModifier(String)
    case unknownKey(String)
    case noModifier(String)
    case shiftOnly(String)

    public var description: String {
        switch self {
        case .empty: "empty shortcut"
        case let .unknownModifier(m): "unknown modifier \"\(m)\" (use cmd, ctrl, opt, shift)"
        case let .unknownKey(k): "unknown key \"\(k)\" for the current keyboard layout"
        case let .noModifier(s): "\"\(s)\" has no modifier; a global shortcut without one would swallow that key everywhere"
        case let .shiftOnly(s): "\"\(s)\" only uses shift; it would take over that key's capital or selection everywhere (add cmd, ctrl or opt)"
        }
    }
}

extension KeyCombo {
    /// Keys whose code doesn't depend on the keyboard layout.
    static let namedKeys: [String: UInt32] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86,
        "keypad5": 87, "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92,
        "keypad.": 65, "keypad*": 67, "keypad+": 69, "keypad/": 75, "keypad-": 78, "keypad=": 81,
    ]

    /// The reverse of `namedKeys`; a code with two names gets the alphabetically first, so output is stable.
    static let nameForKeyCode = Dictionary(namedKeys.map { ($1, $0) }, uniquingKeysWith: min)

    /// F1–F15: the only keys where shift alone is enough, since they type nothing.
    static let functionKeyCodes = Set(namedKeys.filter { $0.key.hasPrefix("f") && $0.key.dropFirst().allSatisfy(\.isNumber) }.values)

    /// Key codes that `KeyLayout` must not claim: the keypad types digits too, but is named apart.
    public static var layoutIndependentKeyCodes: Set<UInt32> { Set(namedKeys.values).union([71]) }

    static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
    ]

    public init(parsing string: String, layout: KeyLayout) throws(KeyComboError) {
        let parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A trailing "+" belongs to the key: "ctrl++" is ctrl and the "+" key, "ctrl+keypad+" is ctrl
        // and the keypad's "+".
        var tokens = parts
        if tokens.count > 2, tokens.last == "" {
            let key = tokens[tokens.count - 2] + "+"
            if key == "+" || Self.namedKeys[key] != nil {
                tokens.removeLast()
                tokens[tokens.count - 1] = key
            }
        }
        guard let keyName = tokens.last, !keyName.isEmpty else { throw .empty }

        var modifiers: Modifiers = []
        for name in tokens.dropLast() {
            guard let modifier = Self.modifierNames[name] else { throw .unknownModifier(name) }
            modifiers.insert(modifier)
        }
        guard !modifiers.isEmpty else { throw .noModifier(string) }

        if let code = Self.namedKeys[keyName] {
            self.init(keyCode: code, modifiers: modifiers)
        } else if let code = layout.keyCode(for: keyName) {
            self.init(keyCode: code, modifiers: modifiers)
        } else if keyName.hasPrefix("keycode"), let code = UInt32(keyName.dropFirst("keycode".count)), code < 128 {
            self.init(keyCode: code, modifiers: modifiers)
        } else {
            throw .unknownKey(keyName)
        }
        if modifiers == .shift, !Self.functionKeyCodes.contains(keyCode) { throw .shiftOnly(string) }
    }

    /// The config-file form, e.g. `ctrl+opt+cmd+w`. Round-trips through `init(parsing:layout:)`.
    public func configString(layout: KeyLayout) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(keyName(layout: layout))
        return parts.joined(separator: "+")
    }

    /// The menu form, e.g. `⌃⌥⌘W`.
    public func displayString(layout: KeyLayout) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let name = keyName(layout: layout)
        return s + (Self.keySymbols[name] ?? name.uppercased())
    }

    /// How menus show the named keys that have a symbol.
    private static let keySymbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "enter": "⌤",
        "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋", "forwarddelete": "⌦",
    ]

    private func keyName(layout: KeyLayout) -> String {
        if let character = layout.characterForKeyCode[keyCode] { return character }
        if let name = Self.nameForKeyCode[keyCode] { return name }
        return "keycode\(keyCode)"
    }
}
