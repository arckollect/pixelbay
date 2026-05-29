// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayPermissions",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayPermissions", targets: ["PixelbayPermissions"])
    ],
    dependencies: [
        .package(path: "../PixelbayDesignSystem")
    ],
    targets: [
        .target(
            name: "PixelbayPermissions",
            dependencies: ["PixelbayDesignSystem"]
        ),
        .testTarget(
            name: "PixelbayPermissionsTests",
            dependencies: ["PixelbayPermissions"]
        )
    ]
)
