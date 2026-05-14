// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayInputCapture",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayInputCapture", targets: ["PixelbayInputCapture"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore")
    ],
    targets: [
        .target(
            name: "PixelbayInputCapture",
            dependencies: ["PixelbayCore"]
        ),
        .testTarget(
            name: "PixelbayInputCaptureTests",
            dependencies: ["PixelbayInputCapture"]
        )
    ]
)
