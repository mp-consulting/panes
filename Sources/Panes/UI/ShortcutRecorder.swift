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

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .symbolEffect(.pulse, isActive: isRecording)
                        .foregroundStyle(isRecording ? .primary : .secondary)
                    Text(label)
                        .font(.body.weight(key.isEmpty || isRecording ? .regular : .semibold))
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(isRecording ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
            .controlSize(.large)

            if !key.isEmpty, !isRecording {
                Button("Clear shortcut", systemImage: "xmark.circle.fill") { key = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: isRecording)
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        if key.isEmpty { return placeholder }
        return store.display(key) ?? key
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        store.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), cocoaFlags: flags.rawValue)
            if combo.modifiers.isEmpty {
                if event.keyCode == 53 { stop() } else { NSSound.beep() } // escape cancels
                return nil
            }
            key = combo.configString(layout: store.layout)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        store.isRecordingShortcut = false
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
