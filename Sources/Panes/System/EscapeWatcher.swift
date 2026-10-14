import CoreGraphics
import Foundation

/// Reports one press of Escape, wherever it goes. A local `NSEvent` monitor can't do this during a
/// SwiftUI drag: the gesture tracks the mouse in a loop that leaves key events queued until the
/// button is released. A listen-only event tap sees the key as it's pressed; it needs the
/// Accessibility access Panes already has for moving windows.
@MainActor final class EscapeWatcher {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onEscape: (() -> Void)?

    /// Calls `onEscape` on the next Escape press, then stops watching.
    func start(_ onEscape: @escaping () -> Void) {
        stop()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<EscapeWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Common modes include event tracking, the mode the drag loop runs the main run loop in.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        self.onEscape = onEscape
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        onEscape = nil
    }

    isolated deinit {
        stop()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53: // escape
            let onEscape = self.onEscape
            stop()
            onEscape?()
        default:
            break
        }
    }
}
