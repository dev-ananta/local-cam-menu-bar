// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalCamCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LocalCamCore", targets: ["LocalCamCore"])
    ],
    targets: [
        .target(
            name: "LocalCamCore",
            path: "Sources/Core"
        ),
        .testTarget(
            name: "LocalCamCoreTests",
            dependencies: ["LocalCamCore"],
            path: "Tests/LocalCamCoreTests"
        )
    ]
)
