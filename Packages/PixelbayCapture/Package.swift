// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelbayCapture",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PixelbayCapture", targets: ["PixelbayCapture"])
    ],
    dependencies: [
        .package(path: "../PixelbayCore")
    ],
    targets: [
        .target(
            name: "PixelbayCapture",
            dependencies: ["PixelbayCore"]
        ),
        .testTarget(
            name: "PixelbayCaptureTests",
            dependencies: ["PixelbayCapture"]
        )
    ]
)
