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
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
