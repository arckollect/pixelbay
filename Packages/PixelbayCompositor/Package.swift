// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayCompositor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayCompositor", targets: ["PixelbayCompositor"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore")
    ],
    targets: [
        .target(
            name: "PixelbayCompositor",
            dependencies: ["PixelbayCore"],
            exclude: ["Shaders.metal"]
        ),
        .testTarget(
            name: "PixelbayCompositorTests",
            dependencies: ["PixelbayCompositor"]
        )
    ]
)
