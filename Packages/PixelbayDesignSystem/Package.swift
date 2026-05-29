// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayDesignSystem",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayDesignSystem", targets: ["PixelbayDesignSystem"])
    ],
    dependencies: [],
    targets: [
        .target(name: "PixelbayDesignSystem"),
        .testTarget(
            name: "PixelbayDesignSystemTests",
            dependencies: ["PixelbayDesignSystem"]
        )
    ]
)
