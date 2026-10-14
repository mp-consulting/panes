// Lists the connected screens as Panes sees them, the main (menu-bar) screen first.
//   swift scripts/list-screens.swift    (or bin/dev screens)
// Frames are in AppKit coordinates: origin at the bottom-left of the main screen, y up.
import AppKit

// Without an app connection to the window server, a secondary screen's visible frame leaves out
// its menu bar.
_ = NSApplication.shared

func describe(_ rect: CGRect) -> String {
    "\(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
}

for (index, screen) in NSScreen.screens.enumerated() {
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    print("\(index == 0 ? "main" : "  #\(index)")  \(screen.localizedName) (display \(id), scale \(screen.backingScaleFactor)x)")
    print("      frame    \(describe(screen.frame))")
    print("      visible  \(describe(screen.visibleFrame))  (menu bar and Dock excluded)")
}
