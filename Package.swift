// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BorkHosts",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BorkHosts", targets: ["BorkHosts"]),
        .executable(name: "bork-hosts", targets: ["BorkHostsCLI"]),
    ],
    targets: [
        .target(
            name: "HostsCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BorkHosts",
            dependencies: ["HostsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BorkHostsCLI",
            dependencies: ["HostsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HostsCoreTests",
            dependencies: ["HostsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
