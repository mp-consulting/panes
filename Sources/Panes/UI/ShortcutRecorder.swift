import AppKit
import PanesCore
import SwiftUI

/// Click, then press a key combination. Escape cancels; the × clears the shortcut.
struct ShortcutRecorder: View {
    @Binding var key: String
    let store: Store
    var placeholder = "Record shortcut"

    @State private var isRecording = false
    @State private var monitor: Any?
    /// The modifiers held while recording, shown as they're pressed: "⌃⌥…".
    @State private var heldModifiers = ""
    /// Why the last combination was refused, shown for a moment under the button.
    @State private var rejection: String?
    @State private var rejectionTimer: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isRecording ? "record.circle" : "keyboard")
                            .symbolEffect(.pulse, isActive: isRecording)
                            .foregroundStyle(isRecording ? .primary : .secondary)
                        Text(label)
                            .font(.body.weight(key.isEmpty || isRecording ? .regular : .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.numericText())
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(isRecording ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                .controlSize(.large)
                // A hand-edited shortcut that doesn't parse is shown as written, and may not fit.
                .help(store.display(key) == nil && !key.isEmpty ? key : "")

                if !key.isEmpty, !isRecording {
                    Button("Clear shortcut", systemImage: "xmark.circle.fill") { key = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        // The glyph alone is a 16pt target.
                        .padding(4)
                        .contentShape(.circle)
                        .help("Clear shortcut")
                        .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            if let rejection {
                IssueLabel(message: rejection)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2), value: isRecording)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2), value: key)
        .animation(.easeOut(duration: 0.2), value: rejection)
        // Recording suspends every hotkey. Left recording while the user went to another app,
        // they'd all stay off until the user came back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if isRecording { stop() }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return heldModifiers.isEmpty ? "Press keys…" : heldModifiers + "…" }
        if key.isEmpty { return placeholder }
        return store.display(key) ?? key
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        heldModifiers = ""
        store.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .flagsChanged {
                heldModifiers = Self.symbols(for: flags)
                return event
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), cocoaFlags: flags.rawValue)
            if event.keyCode == 53, combo.modifiers.isEmpty { // escape cancels
                stop()
                return nil
            }
            // The parser holds the rules (a modifier, and more than shift); a combo it rejects never registers.
            let string = combo.configString(layout: store.layout)
            do throws(KeyComboError) {
                _ = try KeyCombo(parsing: string, layout: store.layout)
            } catch {
                NSSound.beep()
                reject(error)
                return nil
            }
            key = string
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        heldModifiers = ""
        store.isRecordingShortcut = false
    }

    private func reject(_ error: KeyComboError) {
        rejection = switch error {
        case .noModifier, .shiftOnly: "Add ⌘, ⌃ or ⌥: a global shortcut needs one."
        default: "That key can't be used in a shortcut."
        }
        rejectionTimer?.cancel()
        rejectionTimer = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            rejection = nil
        }
    }

    /// In the order menus list them.
    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
    }
}

/// Lets `.buttonStyle` switch between the two glass styles, which are different types.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
