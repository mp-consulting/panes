import AppKit
import ApplicationServices
import PanesCore

/// Moves another app's focused window through the Accessibility API.
@MainActor enum WindowMover {
    enum Failure: Error {
        case notTrusted
        case noWindow
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "would like to control this computer" prompt (once per app version).
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt, a C global that Swift 6 won't read off the main actor's guard.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func move(windowOf app: NSRunningApplication, to selection: GridSelection) throws(Failure) {
        guard isTrusted else { throw .notTrusted }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute),
              let current = frame(of: window)
        else { throw .noWindow }

        let target = selection.frame(in: visibleArea(for: current))

        // With enhanced UI on (set by assistive apps, and by some apps on themselves), every setter
        // animates and the second one lands on a stale frame.
        let enhancedKey = "AXEnhancedUserInterface" as CFString
        let enhanced: Bool = attribute(appElement, enhancedKey) ?? false
        if enhanced { AXUIElementSetAttributeValue(appElement, enhancedKey, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(appElement, enhancedKey, kCFBooleanTrue) } }

        // Size, then position, then size again: shrinking first lets the move onto a smaller
        // screen succeed, and the second resize wins over apps that clamp to the old screen.
        set(window, kAXSizeAttribute, size: target.size)
        set(window, kAXPositionAttribute, point: target.origin)
        set(window, kAXSizeAttribute, size: target.size)
    }

    /// The visible frame (menu bar and Dock excluded), in Accessibility coordinates, of the screen
    /// holding most of `windowFrame`.
    static func visibleArea(for windowFrame: CGRect) -> CGRect {
        let screen = screen(for: windowFrame)
        return flipped(screen.visibleFrame, primaryScreenHeight: primaryHeight)
    }

    static func screen(for windowFrame: CGRect) -> NSScreen {
        let screens = NSScreen.screens
        let best = screens.max { a, b in
            overlap(windowFrame, a) < overlap(windowFrame, b)
        }
        if let best, overlap(windowFrame, best) > 0 { return best }
        return NSScreen.main ?? screens[0]
    }

    /// The frame, in Accessibility coordinates, of `app`'s focused window.
    static func focusedWindowFrame(of app: NSRunningApplication?) -> CGRect? {
        guard isTrusted, let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        return frame(of: window)
    }

    static var primaryScreenHeight: CGFloat { primaryHeight }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func overlap(_ axFrame: CGRect, _ screen: NSScreen) -> CGFloat {
        let screenFrame = flipped(screen.frame, primaryScreenHeight: primaryHeight)
        let intersection = axFrame.intersection(screenFrame)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(window, kAXPositionAttribute),
              let size: AXValue = attribute(window, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        attribute(element, name as CFString)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }

    private static func set(_ element: AXUIElement, _ name: String, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, name as CFString, value) }
    }

    private static func set(_ element: AXUIElement, _ name: String, point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, name as CFString, value) }
    }
}
