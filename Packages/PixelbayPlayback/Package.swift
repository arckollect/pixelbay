// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayPlayback",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayPlayback", targets: ["PixelbayPlayback"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore"),
        .package(path: "../PixelbayCompositor")
    ],
    targets: [
        .target(
            name: "PixelbayPlayback",
            dependencies: ["PixelbayCore", "PixelbayCompositor"]
        ),
        .testTarget(
            name: "PixelbayPlaybackTests",
            dependencies: ["PixelbayPlayback"]
        )
    ]
)
