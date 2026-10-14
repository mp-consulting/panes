import CoreGraphics

/// Choices among the connected screens. Frames are in Accessibility coordinates (top-left of the
/// primary screen, y down), the window's as well as the screens'.
public enum ScreenLayout {
    /// The index of the screen holding most of `window`, or `nil` when it's on none of them.
    public static func index(holdingMostOf window: CGRect, in screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }

    /// The screen after `index`, left to right (top to bottom when they share a left edge), wrapping
    /// round, so pressing the same shortcut again walks through every screen.
    public static func index(after index: Int, in screens: [CGRect]) -> Int {
        let order = leftToRight(screens)
        guard let position = order.firstIndex(of: index) else { return order.first ?? index }
        return order[(position + 1) % order.count]
    }

    /// The order a screen picker lists them in: the primary screen (the first, as `NSScreen.screens`
    /// lists them), then the others left to right.
    public static func pickerOrder(of screens: [CGRect]) -> [Int] {
        guard !screens.isEmpty else { return [] }
        return [0] + leftToRight(screens).filter { $0 != 0 }
    }

    private static func leftToRight(_ screens: [CGRect]) -> [Int] {
        screens.indices.sorted { a, b in
            (screens[a].minX, screens[a].minY, a) < (screens[b].minX, screens[b].minY, b)
        }
    }
}

/// Where a preset shortcut last put a window, so pressing the same shortcut again can tell that the
/// window is still there and send it to the next screen.
public struct Placement: Equatable, Sendable {
    public var processID: Int32
    public var area: GridSelection
    /// The frame read back after the move, not the one asked for: apps with a minimum size or a size
    /// step (Terminal's character cells) don't take the exact frame.
    public var frame: CGRect

    public init(processID: Int32, area: GridSelection, frame: CGRect) {
        self.processID = processID
        self.area = area
        self.frame = frame
    }

    /// Whether `area` is being applied again to a window of the same app that hasn't moved since.
    public func isRepeated(area: GridSelection, processID: Int32, frame: CGRect) -> Bool {
        // A point of slack: some apps report fractional frames that round differently on the way back.
        let slack: CGFloat = 1
        return self.processID == processID && self.area == area
            && abs(self.frame.minX - frame.minX) <= slack && abs(self.frame.minY - frame.minY) <= slack
            && abs(self.frame.width - frame.width) <= slack && abs(self.frame.height - frame.height) <= slack
    }
}
