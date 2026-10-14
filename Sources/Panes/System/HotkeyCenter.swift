import Carbon
import PanesCore

/// Global shortcuts through Carbon's `RegisterEventHotKey`: works without Accessibility
/// permission and consumes the key press, so the frontmost app never sees it.
@MainActor final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private static let signature: OSType = 0x504E_4553 // 'PNES'
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private init() {}

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Replaces every registration. Returns the combos the system refused, usually because another
    /// app (Divvy, Rectangle…) already holds them.
    @discardableResult
    func replace(with bindings: [(combo: KeyCombo, action: () -> Void)]) -> [KeyCombo] {
        unregisterAll()
        var refused: [KeyCombo] = []
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.combo.keyCode, binding.combo.modifiers.rawValue,
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &ref
            )
            if status == noErr, let ref {
                registered.append(ref)
                actions[id] = binding.action
            } else {
                refused.append(binding.combo)
            }
        }
        return refused
    }

    func unregisterAll() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        actions.removeAll()
    }
}
