// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PixelbayCore",
            targets: ["PixelbayCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "PixelbayCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections")
            ]
        ),
        .testTarget(
            name: "PixelbayCoreTests",
            dependencies: ["PixelbayCore"]
        )
    ]
)
