// Renders the app icon: a glassy squircle holding a 3x3 grid with a highlighted area.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appending(path: "Panes-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the shape sits inside a 824/1024 square.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.36, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.15, green: 0.72, blue: 0.86, alpha: 1)])!.draw(in: shape, angle: -60)
    NSGradient(colors: [.white.withAlphaComponent(0.35), .white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: body.insetBy(dx: body.width * 0.02, dy: body.width * 0.02),
                               xRadius: body.width * 0.21, yRadius: body.width * 0.21), angle: -90)

    let inset = body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17)
    let gap = inset.width * 0.05
    let cell = (inset.width - 2 * gap) / 3
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = NSRect(x: inset.minX + CGFloat(column) * (cell + gap), y: inset.minY + CGFloat(row) * (cell + gap),
                              width: cell, height: cell)
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: rect, xRadius: cell * 0.18, yRadius: cell * 0.18).fill()
        }
    }
    // The selected area: the two left columns, full height.
    let selected = NSRect(x: inset.minX, y: inset.minY, width: 2 * cell + gap, height: inset.height)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: selected, xRadius: cell * 0.18, yRadius: cell * 0.18).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
