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
    dependencies: [],
    targets: [
        .target(name: "PixelbayPermissions"),
        .testTarget(
            name: "PixelbayPermissionsTests",
            dependencies: ["PixelbayPermissions"]
        )
    ]
)
