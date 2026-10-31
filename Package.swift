// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SafariProfileSwitcher",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(
            name: "SafariProfileSwitcher",
            dependencies: ["SwitcherCore"],
            resources: [.process("Resources")],
            swiftSettings: [.define("SELF_TEST", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"]
        ),
        .testTarget(
            name: "SafariProfileSwitcherTests",
            dependencies: ["SafariProfileSwitcher", "SwitcherCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
