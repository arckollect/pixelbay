// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayTimelineUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayTimelineUI", targets: ["PixelbayTimelineUI"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore"),
        .package(path: "../PixelbayEditor"),
        .package(path: "../PixelbayPlayback"),
        .package(path: "../PixelbayDesignSystem")
    ],
    targets: [
        .target(
            name: "PixelbayTimelineUI",
            dependencies: ["PixelbayCore", "PixelbayEditor", "PixelbayPlayback", "PixelbayDesignSystem"]
        ),
        .testTarget(
            name: "PixelbayTimelineUITests",
            dependencies: ["PixelbayTimelineUI"]
        )
    ]
)
