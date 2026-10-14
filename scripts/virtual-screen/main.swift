// A virtual display for testing placement on more than one screen without a second monitor.
//   virtual-screen [width height] [--no-view]
// The display exists while this runs; quit (⌘Q, closing the live view, Ctrl-C) to remove it.
// Nothing shows a virtual display, so a window on the main screen mirrors it live. That needs
// Screen Recording for the app that started this (Terminal, VS Code); --no-view skips it.
// Adding or removing a display rebuilds the display configuration, which can switch HDR off on the
// real screens; screens that had HDR on are switched back on after each change and on exit.
// Built and run by `bin/dev screen`. Uses CoreGraphics' private CGVirtualDisplay (VirtualDisplay.h)
// and SkyLight's private HDR switches.
import AppKit
import CoreMedia
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments.dropFirst()
let showView = !arguments.contains("--no-view")
let numbers = arguments.compactMap { UInt32($0) }
let width: UInt32 = numbers.count >= 2 ? numbers[0] : 1920
let height: UInt32 = numbers.count >= 2 ? numbers[1] : 1080

/// SkyLight's HDR switches, looked up at run time so a macOS without them only loses the HDR repair.
enum HDR {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    // The two trailing ints are unknown; callers pass 0, as BetterDisplay-style tools do.
    private typealias Setter = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> CGError

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(skyLight, name).map { unsafeBitCast($0, to: type) }
    }
    private static let supports = symbol("SLSDisplaySupportsHDRMode", as: Query.self)
    private static let isEnabled = symbol("SLSDisplayIsHDRModeEnabled", as: Query.self)
    private static let setEnabled = symbol("SLSDisplaySetHDRModeEnabled", as: Setter.self)

    /// The online displays with HDR on.
    static func enabledDisplays() -> [CGDirectDisplayID] {
        guard let supports, let isEnabled else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { supports($0) && isEnabled($0) }
    }

    /// Switches HDR back on for any of `displays` that lost it.
    static func restore(_ displays: [CGDirectDisplayID]) {
        guard let supports, let isEnabled, let setEnabled else { return }
        for id in displays where supports(id) && !isEnabled(id) {
            let result = setEnabled(id, true, 0, 0)
            print(result == .success ? "Turned HDR back on for display \(id)." : "Couldn't turn HDR back on for display \(id) (\(result.rawValue)).")
        }
    }
}

let hdrDisplays = HDR.enabledDisplays()
var pendingRestore: DispatchWorkItem?

/// Restores HDR once the configuration has settled: a change arrives as several callbacks.
func scheduleHDRRestore(after delay: Double = 1) {
    guard !hdrDisplays.isEmpty else { return }
    pendingRestore?.cancel()
    let work = DispatchWorkItem { HDR.restore(hdrDisplays) }
    pendingRestore = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
}

CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async { scheduleHDRRestore() }
}, nil)

let descriptor = CGVirtualDisplayDescriptor()
descriptor.queue = DispatchQueue.main
descriptor.name = "Panes Test Screen"
descriptor.maxPixelsWide = width
descriptor.maxPixelsHigh = height
// About 90 dpi, so macOS treats it as an ordinary external monitor.
descriptor.sizeInMillimeters = CGSize(width: Double(width) * 0.28, height: Double(height) * 0.28)
descriptor.vendorID = 0x5041
descriptor.productID = 0x4e45
descriptor.serialNum = 0x0001
descriptor.terminationHandler = { _, _ in print("The virtual display was removed by the system.") }

guard let created = CGVirtualDisplay(descriptor: descriptor) else {
    print("Couldn't create the virtual display.")
    exit(1)
}
// The display lives as long as this object: `shutDown()` releases it to remove the display.
var display: CGVirtualDisplay? = created
let displayID = created.displayID
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)]
guard created.apply(settings) else {
    print("Couldn't apply the display mode.")
    exit(1)
}
if !hdrDisplays.isEmpty { print("Keeping HDR on for display \(hdrDisplays.map(String.init).joined(separator: ", ")).") }
print("Added \"Panes Test Screen\", \(width)×\(height) (display \(displayID)). Arrange it in System Settings → Displays.")
print("Quit with Ctrl-C\(showView ? ", ⌘Q or by closing the live view" : "") to remove it.")

/// The app this tool runs inside (Terminal, iTerm, VS Code…): macOS asks it, not the tool, for
/// Screen Recording. Found by walking up the parent processes to the first regular app; VS Code's
/// terminal sits in a helper process inside it.
func hostApp() -> String? {
    var pid = getppid()
    while pid > 1 {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app.bundleURL.map { FileManager.default.displayName(atPath: $0.path) } ?? app.localizedName
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

final class Viewer: NSObject, SCStreamOutput, SCStreamDelegate, NSApplicationDelegate {
    let window: NSWindow
    let layer = CALayer()
    /// Shown over the view until the first frame arrives, and when capture fails.
    let status = NSTextField(wrappingLabelWithString: "Waiting for the first frame…")
    var stream: SCStream?
    var hasFrames = false

    override init() {
        let size = NSSize(width: 960, height: 960 * Double(height) / Double(width))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Panes Test Screen (live view)"
        window.contentAspectRatio = size
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        // Layer-hosting: the layer is set before wantsLayer, so AppKit leaves its contents alone.
        // The other way round makes the view layer-backed, and AppKit clears what the stream sets.
        let host = NSView()
        host.layer = layer
        host.wantsLayer = true
        status.textColor = .white
        status.alignment = .center
        status.font = .systemFont(ofSize: 15)
        status.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8),
        ])
        window.contentView = host
        window.isReleasedWhenClosed = false
    }

    /// Says why the view is black, in the window and in the terminal.
    func report(_ message: String) {
        print(message)
        status.stringValue = message
        status.isHidden = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard showView else { return }
        // On the main (menu-bar) screen, so the view never mirrors itself.
        if let main = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: main.visibleFrame.minX + 40, y: main.visibleFrame.minY + 40))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await startCapture(attempt: 0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { showView }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutDown()
        return .terminateLater
    }

    func startCapture(attempt: Int) async {
        do {
            let content = try await SCShareableContent.current
            guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
                // The display takes a moment to become capturable.
                if attempt < 20 {
                    try await Task.sleep(for: .milliseconds(250))
                    return await startCapture(attempt: attempt + 1)
                }
                return report("The virtual display never became capturable, so there's no live view.")
            }
            let config = SCStreamConfiguration()
            config.width = Int(width)
            config.height = Int(height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            let filter = SCContentFilter(display: target, excludingWindows: [])
            filter.includeMenuBar = true
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            // Capture needs Screen Recording for the app this runs in (Terminal, VS Code…). Checked
            // only once capture has failed: the check can say no where capture would have worked.
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                let app = hostApp().map { "“\($0)”" } ?? "your terminal app"
                return report("""
                    No live view: Screen Recording is off for \(app), which this runs in.
                    Allow \(app) in System Settings → Privacy & Security → Screen & System Audio Recording, \
                    quit and reopen it, then run bin/dev screen again. The test screen works without it.
                    """)
            }
            report("No live view: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames where nothing changed carry no image; the layer keeps the last one.
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        layer.contents = surface
        if !hasFrames {
            hasFrames = true
            status.isHidden = true
            print("Live view running.")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.report("The live view stopped: \(error.localizedDescription)") }
    }
}

/// Removes the display, waits for the configuration to settle, puts HDR back, then exits.
func shutDown() {
    guard display != nil else { return }
    viewer.stream?.stopCapture { _ in }
    display = nil
    print("Removed the virtual display.")
    pendingRestore?.cancel()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        HDR.restore(hdrDisplays)
        exit(0)
    }
}

for signal in [SIGINT, SIGTERM] {
    Foundation.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler { shutDown() }
    source.resume()
    _ = Unmanaged.passRetained(source)
}

let app = NSApplication.shared
let viewer = Viewer()
app.delegate = viewer
// Without the live view there's no window, so stay out of the Dock and ⌘-Tab.
app.setActivationPolicy(showView ? .regular : .accessory)
app.run()
