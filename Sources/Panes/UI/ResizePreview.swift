import AppKit
import SwiftUI

/// A click-through glass outline on the real screen showing where the window will land, like
/// Divvy's resize preview. It sits just under the grid panel and glides between selections.
@MainActor final class ResizePreview {
    private var window: NSPanel?
    /// Counts fade-outs, so one that a `show` interrupted doesn't order the outline out when it ends.
    private var hides = 0
    private var isHiding = false

    /// - Parameter frame: in AppKit screen coordinates.
    func show(_ frame: NSRect) {
        let window = self.window ?? makeWindow()
        self.window = window
        isHiding = false
        // Still on screen, even fading out, it glides to the new frame from where it is. With Reduce
        // Motion it moves at once instead, and only its opacity animates.
        if window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            window.setFrame(frame, display: true)
            if !window.isVisible {
                window.alphaValue = 0
                window.orderFront(nil)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    /// Fades out the way it faded in, rather than vanishing: as the grid closes, the outline gives
    /// way to the window landing in it.
    func hide() {
        guard let window, window.isVisible, !isHiding else { return }
        isHiding = true
        hides += 1
        let hide = hides
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding, self.hides == hide else { return }
                self.isHiding = false
                self.window?.orderOut(nil)
            }
        }
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewShape())
        return window
    }
}

private struct PreviewShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.10))
            .glassEffect(.regular.tint(.accentColor.opacity(0.22)), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3)
            }
            .padding(6)
    }
}
