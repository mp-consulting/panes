import SwiftUI

/// A titled Liquid Glass card, the building block of the settings panes.
struct GlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Soft colour fields behind the settings content. Liquid Glass refracts what is behind it, and on a
/// flat window background it would read as plain grey.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.55 : 0.35
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.62, 0.42], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                .indigo.opacity(strength), .blue.opacity(strength * 0.6), .teal.opacity(strength),
                .purple.opacity(strength * 0.5), .clear, .cyan.opacity(strength * 0.5),
                .pink.opacity(strength * 0.6), .orange.opacity(strength * 0.35), .indigo.opacity(strength * 0.7),
            ]
        )
        .background(.background)
        .ignoresSafeArea()
    }
}

/// A one-line warning shown under the field it concerns.
struct IssueLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .symbolRenderingMode(.multicolor)
    }
}

/// A switch at the trailing edge, so switches line up with each other and with the steppers above
/// them instead of following their labels.
struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                // Read out by the switch itself.
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

extension ToggleStyle where Self == TrailingSwitchToggleStyle {
    static var trailingSwitch: TrailingSwitchToggleStyle { .init() }
}
