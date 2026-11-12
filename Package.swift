// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "TetherCore",
            path: "Sources/TetherCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Tether",
            dependencies: ["TetherCore"],
            path: "Sources/Tether",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TetherCoreTests",
            dependencies: ["TetherCore"],
            path: "Tests/TetherCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
