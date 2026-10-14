// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Panes",
    // macOS 26 is the first release with the Liquid Glass APIs the UI is built on.
    platforms: [.macOS(.v26)],
    targets: [
        // Pure logic (grid geometry, shortcut strings, config, Divvy import): testable without a UI.
        .target(name: "PanesCore"),
        // The menu-bar app: hotkeys, grid panel, settings window, Accessibility window moves.
        .executableTarget(
            name: "Panes",
            dependencies: ["PanesCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "PanesCoreTests", dependencies: ["PanesCore"]),
    ]
)
