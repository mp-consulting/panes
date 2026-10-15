import AppKit
import ApplicationServices
import PanesCore

/// Moves another app's focused window through the Accessibility API.
@MainActor enum WindowMover {
    enum Failure: Error {
        case notTrusted
        case noWindow
        /// No display at all, e.g. a closed laptop with nothing attached.
        case noScreen
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

    /// An app's focused window, looked up once: finding the app's process can mean scanning every
    /// running one (see `processID(of:)`), and a shortcut needs the window's frame before moving it.
    struct FocusedWindow {
        let processID: pid_t
        /// In Accessibility coordinates, as it was when looked up.
        let frame: CGRect
        fileprivate let app: AXUIElement
        fileprivate let element: AXUIElement
    }

    static func focusedWindow(of app: NSRunningApplication) throws(Failure) -> FocusedWindow {
        guard isTrusted else { throw .notTrusted }
        guard let pid = processID(of: app) else { throw .noWindow }
        let appElement = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute),
              let frame = frame(of: window)
        else { throw .noWindow }
        return FocusedWindow(processID: pid, frame: frame, app: appElement, element: window)
    }

    /// Fills `selection` of `screen`, or of the screen the window is mostly on when `nil`, with
    /// `window`, and returns the frame the window ended up with.
    @discardableResult
    static func move(_ window: FocusedWindow, to selection: GridSelection, on screen: NSScreen? = nil) throws(Failure) -> CGRect {
        guard let area = screen.map(visibleArea(of:)) ?? visibleArea(for: window.frame) else { throw .noScreen }
        let target = selection.frame(in: area)

        // With enhanced UI on (set by assistive apps, and by some apps on themselves), every setter
        // animates and the second one lands on a stale frame.
        let enhancedKey = "AXEnhancedUserInterface" as CFString
        let enhanced: Bool = attribute(window.app, enhancedKey) ?? false
        if enhanced { AXUIElementSetAttributeValue(window.app, enhancedKey, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(window.app, enhancedKey, kCFBooleanTrue) } }

        // Size, then position, then size again: shrinking first lets the move onto a smaller
        // screen succeed, and the second resize wins over apps that clamp to the old screen.
        set(window.element, kAXSizeAttribute, size: target.size)
        set(window.element, kAXPositionAttribute, point: target.origin)
        set(window.element, kAXSizeAttribute, size: target.size)
        return frame(of: window.element) ?? target
    }

    /// The visible frame (menu bar and Dock excluded), in Accessibility coordinates, of the screen
    /// holding most of `windowFrame`.
    static func visibleArea(for windowFrame: CGRect) -> CGRect? {
        screen(for: windowFrame).map(visibleArea(of:))
    }

    /// `screen`'s visible frame (menu bar and Dock excluded), in Accessibility coordinates.
    static func visibleArea(of screen: NSScreen) -> CGRect {
        flipped(screen.visibleFrame, primaryScreenHeight: primaryHeight)
    }

    /// `screen`'s whole frame, in Accessibility coordinates.
    static func frame(of screen: NSScreen) -> CGRect {
        flipped(screen.frame, primaryScreenHeight: primaryHeight)
    }

    static func screen(for windowFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = ScreenLayout.index(holdingMostOf: windowFrame, in: screens.map(frame(of:))) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }

    /// The screen after the one holding most of `windowFrame`, left to right, wrapping round.
    static func screen(after windowFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let frames = screens.map(frame(of:))
        guard let current = ScreenLayout.index(holdingMostOf: windowFrame, in: frames) else { return nil }
        return screens[ScreenLayout.index(after: current, in: frames)]
    }

    /// `app`'s process ID. Some apps (Preview on macOS 26) come back from NSWorkspace with a
    /// `processIdentifier` of -1, even when looked up by their own pid, so this falls back to the
    /// running process whose executable is the app's.
    static func processID(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let executable = app.executableURL?.resolvingSymlinksInPath().path else { return nil }
        // Checked again before use: the app may have quit and come back under another pid.
        if let pid = foundProcessIDs[executable], executablePath(of: pid) == executable { return pid }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        // Matching names first: the kernel keeps them at hand, while a path is resolved on disk.
        let name = Array((executable as NSString).lastPathComponent.utf8)
        var nameBuffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let pid = pids.prefix(Int(max(filled, 0))).first { pid in
            guard pid > 0 else { return false }
            let length = Int(proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)))
            // The kernel cuts long names short, so a prefix is a match too.
            guard length > 0, name.starts(with: nameBuffer.prefix(length)) else { return false }
            return executablePath(of: pid) == executable
        }
        if let pid { foundProcessIDs[executable] = pid }
        return pid
    }

    /// Processes found by `processID(of:)`, by executable path.
    private static var foundProcessIDs: [String: pid_t] = [:]

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self)).resolvingSymlinksInPath().path
    }

    static var primaryScreenHeight: CGFloat { primaryHeight }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

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
