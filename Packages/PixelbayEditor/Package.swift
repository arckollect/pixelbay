// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayEditor", targets: ["PixelbayEditor"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore"),
        .package(path: "../PixelbayInputCapture")
    ],
    targets: [
        .target(
            name: "PixelbayEditor",
            dependencies: ["PixelbayCore", "PixelbayInputCapture"]
        ),
        .testTarget(
            name: "PixelbayEditorTests",
            dependencies: ["PixelbayEditor"]
        )
    ]
)
