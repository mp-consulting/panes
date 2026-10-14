import Carbon
import PanesCore

/// Reads the active keyboard layout so shortcut letters match the keycaps (AZERTY, QWERTZ, …).
enum KeyboardLayout {
    static func current() -> KeyLayout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return .usANSI }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let skipped = KeyCombo.layoutIndependentKeyCodes

        var map: [UInt32: String] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 where !skipped.contains(UInt32(code)) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: chars, count: length).lowercased()
                guard let scalar = string.unicodeScalars.first,
                      !CharacterSet.controlCharacters.union(.whitespaces).contains(scalar),
                      !string.contains("+")
                else { continue }
                map[UInt32(code)] = string
            }
        }
        return map.isEmpty ? .usANSI : KeyLayout(characterForKeyCode: map)
    }
}
